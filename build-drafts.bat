rmdir "drafts-ru" /s /q
rmdir "drafts-en" /s /q
rmdir "ru/_site" /s /q
rmdir "en/_site" /s /q
xcopy "ru" "drafts-ru" /i /s /y
xcopy "en" "drafts-en" /i /s /y
rmdir "drafts-ru/_posts" /s /q
rmdir "drafts-en/_posts" /s /q
xcopy "drafts-ru/_drafts" "drafts-ru/_posts" /i /s /y
xcopy "drafts-en/_drafts" "drafts-en/_posts" /i /s /y
bin\Pretzel.exe bake drafts-ru
xcopy "drafts-ru/_site" "drafts-en/_site" /i /s /y
xcopy "_files/data" "drafts-en/_site/data" /i /s /y
xcopy "_files/ru" "drafts-en/_site/ru" /i /s /y
xcopy "_files/en" "drafts-en/_site/en" /i /s /y
start bin\Pretzel.exe taste drafts-en