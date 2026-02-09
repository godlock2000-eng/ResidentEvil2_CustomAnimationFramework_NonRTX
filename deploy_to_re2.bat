@echo off
REM Deploy CustomAnimFramework to RE2 game directory
REM Run this from the project root directory

REM *** Set this to YOUR RE2 game directory ***
set GAME_DIR=C:\SteamLibrary\steamapps\common\RESIDENT EVIL 2  BIOHAZARD RE2
set SRC_DIR=%~dp0framework\reframework

echo Deploying CustomAnimFramework to RE2...
echo Source: %SRC_DIR%
echo Target: %GAME_DIR%\reframework
echo.

REM Copy autorun script
echo Copying CustomAnimFramework.lua...
copy /Y "%SRC_DIR%\autorun\CustomAnimFramework.lua" "%GAME_DIR%\reframework\autorun\CustomAnimFramework.lua"

REM Copy data files
echo Copying data files...
if not exist "%GAME_DIR%\reframework\data\CustomAnimFramework" mkdir "%GAME_DIR%\reframework\data\CustomAnimFramework"
copy /Y "%SRC_DIR%\data\CustomAnimFramework\dodge_dump.txt" "%GAME_DIR%\reframework\data\CustomAnimFramework\dodge_dump.txt"
copy /Y "%SRC_DIR%\data\CustomAnimFramework\dodge_dump_named.txt" "%GAME_DIR%\reframework\data\CustomAnimFramework\dodge_dump_named.txt"

echo.
echo Deployment complete!
echo Start RE2 with REFramework to test.
pause
