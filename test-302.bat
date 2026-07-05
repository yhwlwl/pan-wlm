@echo off
echo ========================================
echo   302 直链内测 — 验证下载不走 ECS
echo ========================================
echo.
echo 先确认 npm run dev 已经启动 (localhost:3000)
echo.
pause
echo.
echo [1/3] 登录获取 token...

curl -sk -X POST "http://localhost:3000/api/login" ^
  -H "Content-Type: application/json" ^
  -d "{\"password\":\"123456\"}" ^
  -w "\nHTTP %%{http_code}\n" 2>&1

echo.
echo [2/3] 复制上面的 token，然后填到下面...
set /p TOKEN="粘贴 token: "

echo.
echo [3/3] 测试下载重定向 (看 Location 头是否为百度 CDN)...

curl -sk -I "http://localhost:3000/api/alist-download?path=/sta/evimage.xp3&token=%TOKEN%" 2>&1 | findstr /i "location HTTP"

echo.
echo ========================================
echo  如果 Location 是 d.pcs.baidu.com — 成功!
echo  如果 Location 是 pan.tantantan.tech — 没生效
echo ========================================
pause
