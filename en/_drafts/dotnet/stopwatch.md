---
layout: post
title: Stopwatch under the hood
date: "2016-08-02"
category: dotnet
tags:
- .NET
- Hardware
- Timers
---

Today we discuss the [Stopwatch](https://msdn.microsoft.com/library/system.diagnostics.stopwatch.aspx) class: how does it work on different runtimes and operation systems, which hardware timers may be used as a base for Stopwatch, what the granularity and latency of Stopwatch in different environments.

TODO: http://oliveryang.net/2015/09/pitfalls-of-TSC-usage/

TODO: time is tricky, you can create wounderful bugs if you don't understand how it works (see [Falsehoods programmers believe about time](http://infiniteundo.com/post/25326999628/falsehoods-programmers-believe-about-time) and [More falsehoods programmers believe about time](http://infiniteundo.com/post/25509354022/more-falsehoods-programmers-believe-about-time)).

<!-- more -->

### Overview

TODO

---

### Hardware timers

#### TSC

**TSC** — The Time Stamp Counter. It is an internal 64-bit register present on all x86 processors since the Pentium. Can be read into `EDX:EAX` using the instruction `RDTSC`.

Examples: (TODO)

```
Frequency = 3 GHz; Resolution = 333 ns
```

Opcode for `RDTSC` is `0F 31` (see [Intel: Intel® 64 and IA-32 Architectures Software Developer’s Manual](http://www.intel.com/content/dam/www/public/us/en/documents/manuals/64-ia-32-architectures-software-developer-manual-325462.pdf), Vol. 2B 4-302). So, it can be read directly from C# code:

```cs
const uint PAGE_EXECUTE_READWRITE = 0x40;
const uint MEM_COMMIT = 0x1000;

[DllImport("kernel32.dll", SetLastError = true)]
static extern IntPtr VirtualAlloc(IntPtr lpAddress, uint dwSize, 
                                  uint flAllocationType, uint flProtect);

static IntPtr Alloc(byte[] asm)
{
    var ptr = VirtualAlloc(IntPtr.Zero, (uint)asm.Length, 
                           MEM_COMMIT, PAGE_EXECUTE_READWRITE);
    Marshal.Copy(asm, 0, ptr, asm.Length);
    return ptr;
}

delegate long RdtscDelegate();

static readonly byte[] rdtscAsm =
{
    0x0F, 0x31, // rdtsc
    0xC3        // ret
};

static void Main()
{
    var rdtsc = Marshal.GetDelegateForFunctionPointer<RdtscDelegate>(Alloc(rdtscAsm));
    Console.WriteLine(rdtsc());
}
```

TODO: get frequency, see http://stackoverflow.com/questions/23251795/how-to-calculate-the-frequency-of-cpu-cores

##### Problems

There are two problems:

* TSC synchronization across processors
* dynamic changes to the TSC clock update interval as a result of the processor entering a lower power state, slowing both the clock rate and the TSC update interval in tandem. TODO: rewrite

Let's look at the official Intel documentation:

> * For Pentium M processors and for P6 family processors: the time-stamp counter increments with every internal processor clock cycle. The internal processor clock cycle is determined by the current core-clock to bus-
>   clock ratio. Intel® SpeedStep® technology transitions may also impact the processor clock.
> * For Pentium 4 processors, Intel Xeon processors; for Intel Core Solo and Intel Core Duo processors; for the Intel Xeon processor 5100 series and Intel Core 2 Duo processors; for Intel Core 2 and Intel Xeon processors; for Intel Atom processors: the time-stamp counter increments at a constant rate. That rate may be set by the maximum core-clock to bus-clock ratio of the processor or may be set by the maximum resolved frequency at which the processor is booted. The maximum resolved frequency may differ from the maximum qualified frequency of the processor.

> The specific processor configuration determines the behavior. Constant TSC behavior ensures that the duration of each clock tick is uniform and supports the use of the TSC as a wall clock timer even if the processor core changes frequency. This is the architectural behavior moving forward.
> (c) [Intel® 64 and IA-32 Architectures Software Developer’s Manual Volume 3A: System Programming Guide, Part 1](ftp://download.intel.com/design/processor/manuals/253668.pdf), Section 16.12 "Time-stamp counter"

If you have TSC with constant frequency, it calls "Invariant TSC". You can check, if you have this feature with help of the [CPUID](https://en.wikipedia.org/wiki/CPUID) opcode. Processors support for invariant TSC is indicated by `CPUID.80000007H:EDX[8]` (see [Intel® 64 and IA-32 Architectures Software Developer’s Manual](http://www.intel.com/content/dam/www/public/us/en/documents/manuals/64-ia-32-architectures-software-developer-manual-325462.pdf), Vol. 2A 3-190, Table 3-17).

You can also check it via the [Coreinfo](https://technet.microsoft.com/en-us/sysinternals/cc835722) utility. You should just run it and look in the console output for lines like follows:

```
TSC             *       Supports RDTSC instruction
TSC-DEADLINE    *       Local APIC supports one-shot deadline timer
TSC-INVARIANT   *       TSC runs at constant rate
```

So, if you use modern hardware and OS, you shouldn't be worried about TSC drift. However, there are some funny bugs on the old stack of technologies. For example (see [Programs that use the QueryPerformanceCounter function may perform poorly in Windows Server 2000, in Windows Server 2003, and in Windows XP](https://support.microsoft.com/en-us/kb/895980)):

```
C:\>ping x.x.x.x

Pinging x.x.x.x with 32 bytes of data:

Reply from x.x.x.x: bytes=32 time=-59ms TTL=128
Reply from x.x.x.x: bytes=32 time=-59ms TTL=128
Reply from x.x.x.x: bytes=32 time=-59ms TTL=128
Reply from x.x.x.x: bytes=32 time=-59ms TTL=128
```

If you want to use TSC on old hardware/software, you should probably set processor affinity for you thread (see [SetThreadAffinityMask](https://msdn.microsoft.com/library/windows/desktop/ms686247.aspx) for Windows, [sched_setaffinity](http://linux.die.net/man/2/sched_setaffinity) for Linux).


There is another interesting fact, that you should consider, if you want to read the TSC value directly via the `RDTSC` instruction:

> On all processors with out-of-order execution, you have to insert `XOR EAX,EAX`/`CPUID` before and after each read of the counter in order to prevent it from executing in parallel with anything else. `CPUID` is a serializing instruction, which means that it flushes the pipeline and waits for all pending operations to finish before proceeding. This is very useful for testing purposes.
> (c) Agner Fog, [Optimizing subroutines in assembly language. An optimization guide for x86 platforms](http://www.agner.org/optimize/optimizing_assembly.pdf), section 18.1

An example (see [Optimizing software in C++. An optimization guide for Windows, Linux and Mac platforms](http://www.agner.org/optimize/optimizing_cpp.pdf) by Agner Fog, section 16 "Testing speed"):

```cpp
// Example 16.1
#include <intrin.h>         // Or #include <ia32intrin.h> etc.
long long ReadTSC() {       // Returns time stamp counter
    int dummy[4];           // For unused returns
    volatile int DontSkip;  // Volatile to prevent optimizing
    long long clock;        // Time
    __cpuid(dummy, 0);      // Serialize
    DontSkip = dummy[0];    // Prevent optimizing away cpuid
    clock = __rdtsc();      // Read time
    return clock;
}
```

See also: [Game Timing and Multicore Processors](https://msdn.microsoft.com/en-us/library/ee417693.aspx)


TODO: http://www.agner.org/optimize/instruction_tables.pdf

As we can see, TSC have a very good resolution and low latency. However, you wan't to use it in general because there are a lot of problem with TSC (see also: [Acquiring high-resolution time stamps, "TSC Register" section](https://msdn.microsoft.com/library/windows/desktop/dn553408.aspx#AppendixB)):

* Not all processors have TSC registers.
* Some processors can vary the frequency of the TSC clock or stop the advancement of the TSC register.
* On multi-processor or multi-core systems, some processors and systems are unable to synchronize the clocks on each core to the same value.
* On some large multi-processor systems, you might not be able to synchronize the processor clocks to the same value even if the processor has an invariant TSC.
* Some processors will execute instructions out of order.

On the other hand, in some cases, `rdtsc` can be really useful. But you must understand what you're doing. Probably, you want to run a single-thread program, specify affinity for your process and thread, shutdown unnecessary background applications, fix processor frequency, and so on.

##### Latency and Granularity

---

#### ACPI PM and HPET

* **ACPI PM**

Freq = 3.579545 MHz

See [specification](http://www.uefi.org/sites/default/files/resources/ACPI_6.0.pdf), section 4.8.2.1.

* **HPET (High Precision Event Timer)**

Minimum clock frequency: 10 MHz ([IA-PC HPET Specification Rev 1.0a](http://www.intel.com/content/dam/www/public/us/en/documents/technical-specifications/software-developers-hpet-spec-1-0a.pdf), section 2.2). However, in practice usual frequenct is 14.31818 Mhz or 4x the ACPI clock.

Usual Freq: 14.31818 MHz

Enable HPET (reboot is required):

```
bcdedit /set useplatformclock true
```

Disable HPET (reboot is required):
```
bcdedit /deletevalue useplatformclock
```

View all:
```
bcdedit /enum
```

Notes about the same hardware

##### Latency and Granularity

Letency:

```
HPET ON: between 100-150us delay
HPET OFF: between 5-15us delay
```

See also: [StackOverflow: Is QueryPerformanceFrequency acurate when using HPET?](http://stackoverflow.com/q/22942123/184842)

---

### Operation Systems

#### Windows

The best article about time stamps on Windows is [Acquiring high-resolution time stamps](https://msdn.microsoft.com/library/windows/desktop/dn553408.aspx). Brief summary:

On Windows, the primary API for high-resolution time stamps is [QueryPerformanceCounter (QPC)](https://msdn.microsoft.com/library/windows/desktop/ms644904.aspx). For device drivers, the kernel-mode API is [KeQueryPerformanceCounter](https://msdn.microsoft.com/library/windows/desktop/ff553053.aspx). If you need high-resolution time-of-day measurements, use [GetSystemTimePreciseAsFileTime](https://msdn.microsoft.com/library/windows/desktop/hh706895.aspx) (available since Windows 8 / Windows Server 2012).

`QPC` is completely independent of the system time and UTC (it is not affected by daylight savings time, leap seconds, time zones). It is also not affected by processor frequency changes. Thus, it is th best option, if you want to measaure duration of an operation. If you want to know high-precision DateTime, use `GetSystemTimePreciseAsFileTime`.

##### QPC support in Windows versions

* QPC is available on *Windows XP and Windows 2000* and works well on most systems. However, some hardware systems' BIOS didn't indicate the hardware CPU characteristics correctly (a non-invariant TSC), and some multi-core or multi-processor systems used processors with TSCs that couldn't be synchronized across cores. Systems with flawed firmware that run these versions of Windows might not provide the same QPC reading on different cores if they used the TSC as the basis for QPC.
* All computers that shipped with *Windows Vista and Windows Server 2008* used the HPET or the ACPI PM as the basis for QPC.
* The majority of *Windows 7 and Windows Server 2008 R2* computers have processors with constant-rate TSCs and use these counters as the basis for QPC.
* *Windows 8, Windows 8.1, Windows Server 2012, and Windows Server 2012 R2* use TSCs as the basis for the performance counter.

##### API

```cs
[DllImport("kernel32.dll")]
private static extern bool QueryPerformanceCounter(out long value);

[DllImport("kernel32.dll")]
private static extern bool QueryPerformanceFrequency(out long value);
```

##### ASM

```x86asm
00007FFD43C8A3E0  push        rbx  
00007FFD43C8A3E2  sub         rsp,20h  
00007FFD43C8A3E6  mov         al,byte ptr [7FFE03C6h]  
00007FFD43C8A3ED  mov         rbx,rcx  
00007FFD43C8A3F0  cmp         al,1  
00007FFD43C8A3F2  jne         00007FFD43C8A424  
00007FFD43C8A3F4  mov         rcx,qword ptr [7FFE03B8h]  
00007FFD43C8A3FC  rdtsc  
00007FFD43C8A3FE  shl         rdx,20h  
00007FFD43C8A402  or          rax,rdx  
00007FFD43C8A405  mov         qword ptr [rbx],rax  
00007FFD43C8A408  lea         rdx,[rax+rcx]  
00007FFD43C8A40C  mov         cl,byte ptr [7FFE03C7h]  
00007FFD43C8A413  shr         rdx,cl  
00007FFD43C8A416  mov         qword ptr [rbx],rdx  
00007FFD43C8A419  mov         eax,1  
00007FFD43C8A41E  add         rsp,20h  
00007FFD43C8A422  pop         rbx  
00007FFD43C8A423  ret
```

the jne that is based of 7FFE03C6h is never taken
I assume that's some global that signals the the fast-path is "safe" on my machine

I just followed the `00007FFD43C8A424` and it indeed jumps to the kernel (i.e. syscall):

```x86asm
00007FFD43CE5360  mov         r10,rcx  
00007FFD43CE5363  mov         eax,31h  
00007FFD43CE5368  test        byte ptr [7FFE0308h],1  
00007FFD43CE5370  jne         00007FFD43CE5375  
00007FFD43CE5372  syscall  
00007FFD43CE5374  ret
```

basically `00007FFD43C8A424` is `NtQueryPerformanceCounterthat` just jumps to the kernel

Not yet, but it's a common Kernel32/NtDll pattern, to avoid unsupported low-level ops by jumping around based on global vars
I assume that if InvariantTsc is not supposed by the CPU that memory address with be != 1
and it will jump to the kernel for older hw

##### Continuity

There is another intereseting question: is QPC continuous? Short answer: No

https://github.com/somdoron/AsyncIO/commit/5c838f3d30d483dcadb4181233a4437fb5e7f327

##### VirtualBox

---

#### Linux

TODO

---

### Stopwatch implementation

#### Windows + MS.NET/CoreCLR

Stopwatch on MS.NET uses QPC, let's look at the [source](http://referencesource.microsoft.com/#System/services/monitoring/system/diagnosticts/Stopwatch.cs,28):

```cs
public class Stopwatch
{
	private const long TicksPerMillisecond = 10000;
	private const long TicksPerSecond = TicksPerMillisecond * 1000;

	// "Frequency" stores the frequency of the high-resolution performance counter, 
	// if one exists. Otherwise it will store TicksPerSecond. 
	// The frequency cannot change while the system is running,
	// so we only need to initialize it once. 
	public static readonly long Frequency;
	public static readonly bool IsHighResolution;

	// performance-counter frequency, in counts per ticks.
	// This can speed up conversion from high frequency performance-counter 
	// to ticks. 
	private static readonly double tickFrequency;

	static Stopwatch()
	{
		bool succeeded = SafeNativeMethods.QueryPerformanceFrequency(out Frequency);
		if (!succeeded)
		{
			IsHighResolution = false;
			Frequency = TicksPerSecond;
			tickFrequency = 1;
		}
		else
		{
			IsHighResolution = true;
			tickFrequency = TicksPerSecond;
			tickFrequency /= Frequency;
		}
	}

	public static long GetTimestamp()
	{
		if (IsHighResolution)
		{
			long timestamp = 0;
			SafeNativeMethods.QueryPerformanceCounter(out timestamp);
			return timestamp;
		}
		else
		{
			return DateTime.UtcNow.Ticks;
		}
	}
}
```

Typical freq = TSC freq / 1024

---

#### Windows + Mono

Let's look at an [implementation](https://github.com/mono/mono/blob/master/mcs/class/System/System.Diagnostics/Stopwatch.cs) of `Stopwatch` in Mono:

```cs
public class Stopwatch
{
	[MethodImplAttribute(MethodImplOptions.InternalCall)]
	public static extern long GetTimestamp();

	public static readonly long Frequency = 10000000;

	public static readonly bool IsHighResolution = true;
}
```

As you can see, frequency of `Stopwatch` in Mono is a const (10000000). TODO: Latency

---

#### Windows + Linux

---

#### Summary

### Links

#### Useful software

* [CPU-Z](http://www.cpuid.com/softwares/cpu-z.html)
* [ClockRes](https://technet.microsoft.com/en-us/sysinternals/bb897568.aspx)
* [Coreinfo](https://technet.microsoft.com/en-us/sysinternals/cc835722)
* [DPC Latency Checker](http://www.thesycon.de/deu/latency_check.shtml)
* [Harmonic](http://www.bytemedev.com/programs/harmonic-help/)
* [LatencyMon](http://www.resplendence.com/latencymon)

#### Best

* [MSDN: Acquiring high-resolution time stamps](https://msdn.microsoft.com/library/windows/desktop/dn553408.aspx)
* [The Windows Timestamp Project](http://www.windowstimestamp.com/description)

#### MSDN

* [MSDN: BCDEdit](https://msdn.microsoft.com/en-us/library/windows/hardware/ff542202%28v=vs.85%29.aspx)
* [MSDN: DateTime.UtcNow](https://msdn.microsoft.com/library/system.datetime.utcnow.aspx)
* [MSDN: Swopwatch](https://msdn.microsoft.com/library/system.diagnostics.stopwatch.aspx)
* [MSDN: SetThreadAffinityMask](https://msdn.microsoft.com/library/windows/desktop/ms686247.aspx)
* [MSDN: Game Timing and Multicore Processors](https://msdn.microsoft.com/en-us/library/ee417693.aspx)
* [MSDN: VirtualAlloc](https://msdn.microsoft.com/library/windows/desktop/aa366887.aspx)

#### Wiki

* [Wiki: System time](https://en.wikipedia.org/wiki/System_time)
* [Wiki: CPUID](https://en.wikipedia.org/wiki/CPUID)

#### Intel

* [Intel: How to Benchmark Code Execution Times on Intel®IA-32 and IA-64 Instruction Set Architectures](http://www.intel.com/content/dam/www/public/us/en/documents/white-papers/ia-32-ia-64-benchmark-code-execution-paper.pdf)
* [Intel: IA-PC HPET Specification](http://www.intel.com/content/dam/www/public/us/en/documents/technical-specifications/software-developers-hpet-spec-1-0a.pdf)
* [Intel: Intel® 64 and IA-32 Architectures Software Developer’s Manual Volume 3A: System Programming Guide, Part 1](ftp://download.intel.com/design/processor/manuals/253668.pdf)
* [Intel: Intel® 64 and IA-32 Architectures Software Developer’s Manual](http://www.intel.com/content/dam/www/public/us/en/documents/manuals/64-ia-32-architectures-software-developer-manual-325462.pdf)
* [Intel's original CPU TSC Counter guidance for use in game timing (1998)](https://www.ccsl.carleton.ca/~jamuir/rdtscpm1.pdf)

#### Misc

* [Advanced Configuration and Power Interface  Specification 6.0 (April 2015)](http://www.uefi.org/sites/default/files/resources/ACPI_6.0.pdf)
* [RedHat Documentation: Timestamping](https://access.redhat.com/documentation/en-US/Red_Hat_Enterprise_MRG/2/html/Realtime_Reference_Guide/chap-Timestamping.html)
* [Mmo-champion: WinTimerTester](http://www.mmo-champion.com/threads/1215396-WinTimerTester)
* [Mike Martin: Disable HPET](http://www.mikemartin.co/system_guides/hardware/motherboard/disable_high_precision_event_timer_hpet)
* [Manski`s blog: High Resolution Clock in C#](http://manski.net/2014/07/high-resolution-clock-in-csharp/)
* [Coding Horror: Keeping Time on the PC](http://blog.codinghorror.com/keeping-time-on-the-pc/)
* [Random ASCII: Windows Timer Resolution: Megawatts Wasted (2013)](https://randomascii.wordpress.com/2013/07/08/windows-timer-resolution-megawatts-wasted/)
* [Random ASCII: Sleep Variation Investigated (2013)](https://randomascii.wordpress.com/2013/04/02/sleep-variation-investigated/)
* [Random ASCII: rdtsc in the Age of Sandybridge (2011)](https://randomascii.wordpress.com/2011/07/29/rdtsc-in-the-age-of-sandybridge/)
* [MathPirate: Temporal Mechanics: Changing the Speed of Time, Part II](http://www.mathpirate.net/log/2010/03/20/temporal-mechanics-changing-the-speed-of-time-part-ii/)
* [VirtualDub: Beware of QueryPerformanceCounter() (2006)](http://www.virtualdub.org/blog/pivot/entry.php?id=106)
* [The Old New Thing: Precision is not the same as accuracy (2005)](https://blogs.msdn.microsoft.com/oldnewthing/20050902-00/?p=34333/#460003)
* [Luxford: High Performance Windows Timers](http://www.luxford.com/high-performance-windows-timers)
* [Computer Performance By Design: High Resolution Clocks and Timers for Performance Measurement in Windows (2012)](http://computerperformancebydesign.com/high-resolution-clocks-and-timers-for-performance-measurement-in-windows/)
* [Jan Wassenberg: Timing Pitfalls and Solutions (2007)](http://algo2.iti.kit.edu/wassenberg/timing/timing_pitfalls.pdf)
* [support.microsoft.com: Programs that use the QueryPerformanceCounter function may perform poorly](https://support.microsoft.com/en-us/kb/895980)
* [support.microsoft.com: The system clock may run fast when you use the ACPI power management timer as a high-resolution counter](https://support.microsoft.com/en-us/kb/821893)
* [linux.die.net: sched_setaffinity](http://linux.die.net/man/2/sched_setaffinity)
* [NCrunch: How to set a thread's processor affinity in .NET](http://blog.ncrunch.net/post/How-to-set-a-threads-processor-affinity-in-NET.aspx)
* [Hungry Mind: High-Resolution Timer = Time Stamp Counter = RDTSC (2007, In Russian)](http://chabster.blogspot.ru/2007/09/high-resolution-timer-time-stamp.html)
* [How to measure your CPU time: clock_gettime! (2016)](http://jvns.ca/blog/2016/02/20/measuring-cpu-time-with-clock-gettime/)
* [How CPU load averages work (and using them to triage webserver performance!) (2016)](http://jvns.ca/blog/2016/02/07/cpu-load-averages/)

#### StackOverflow

* [StackOverflow: How frequent is DateTime.Now updated?](http://stackoverflow.com/questions/307582/how-frequent-is-datetime-now-updated-or-is-there-a-more-precise-api-to-get-the)
* [StackOverflow: Can the .NET Stopwatch class be THIS terrible?](http://stackoverflow.com/questions/3400254/can-the-net-stopwatch-class-be-this-terrible/3400490#3400490)
* [StackOverflow: How precise is the internal clock of a modern PC?](http://stackoverflow.com/questions/2607263/how-precise-is-the-internal-clock-of-a-modern-pc)
* [StackOverflow: Windows 7 timing functions - How to use GetSystemTimeAdjustment correctly?](http://stackoverflow.com/q/7685762/184842)
* [StackOverflow: What is the acpi_pm linux clocksource used for, what hardware implements it?](http://stackoverflow.com/q/7987671/184842)
* [StackOverflow: Is QueryPerformanceFrequency acurate when using HPET?](http://stackoverflow.com/q/22942123/184842)
* [StackOverflow: Measure precision of timer (e.g. Stopwatch/QueryPerformanceCounter)](http://stackoverflow.com/questions/36318291/measure-precision-of-timer-e-g-stopwatch-queryperformancecounter)