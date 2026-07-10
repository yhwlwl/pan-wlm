# WLM-PAN 技术文档 — 未来梦 PDF 预览站

本文档面向接手项目的开发者和 AI，涵盖完整架构、与主站的关系、核心差异点、API 路由、权限系统、数据库隔离策略及部署方案。

---

## 1. 项目概览

未来梦（wlm.cdqzsta.tech）是基于主站 STA-PAN 复刻的 PDF 预览站。
Next.js 16 + React 19 + AList + PostgreSQL(ECS)。

### 与主站的核心区别

| 维度 | 主站 (baidu-pan-alist) | 未来梦站 (pan-vlm) |
|------|------------------------|-------------------|
| 域名 | pan.cdqzsta.tech | wlm.cdqzsta.tech |
| API 网关 | Nginx /pan/ -> Next.js:3000 | Nginx /wlm-api/ -> Next.js:3001 |
| 用户表 | bdpan_users | wlm_bdpan_users（独立） |
| 设置表 | bdpan_settings | wlm_bdpan_settings（独立） |
| 日志/事件 | 共享，source列区分 |
| 风险评分 | bdpan_risk_scores（完全共享） |
| 根目录 | 所有文件 | 锁定到未来梦扫描件目录 |
| Vercel 源 | stacdqz/bd-pan | yhwlwl/pan-wlm |

---

## 2. 与主站的关系

### 共享资源

- AList：同一实例（pan.tantantan.tech:5244），同一百度网盘
- PostgreSQL + PostgREST：同一 bdpan 数据库，同一 :3100 网关
- 风控系统：bdpan_risk_scores 共享，封禁跨站生效
- 操作日志：bdpan_action_logs 共享，source=weilaimeng 区分
- Deny 事件：bdpan_deny_events 共享，source 列区分
- 访问记录：view_logs 共享，page_source 列区分
- PDF 缓存：共享 Nginx /pdf-preview/

### 独立资源

- 用户账户：wlm_bdpan_users
- 全局设置：wlm_bdpan_settings
- JWT 密钥：与主站相同 ADMIN_TOKEN_SECRET

### 数据流

用户 (wlm.cdqzsta.tech)
  -> Vercel CDN
  -> API https://pan.tantantan.tech/wlm-api/
  -> Nginx /wlm-api/ -> Next.js:3001
  -> wlm_bdpan_users / wlm_bdpan_settings (独立)
  -> bdpan_* 共享表 (source=weilaimeng)
  -> AList (FORCE_BASE_PATH 锁定目录)

---

## 3. 核心差异点

### 3.1 表前缀 DB_TABLE_PREFIX

src/lib/users.ts:
  const PREFIX = process.env.DB_TABLE_PREFIX || '';
  TABLE_USERS = ${PREFIX}bdpan_users;
  TABLE_SETTINGS = ${PREFIX}bdpan_settings;

隔离范围：wlm_bdpan_users(用户), wlm_bdpan_settings(设置)
不隔离(硬编码)：bdpan_deny_events, bdpan_risk_scores, bdpan_action_logs

### 3.2 目录锁定 FORCE_BASE_PATH

所有 AList 请求自动补全路径前缀。用户看不到锁定目录之外的文件。
生效于 alist/route.ts, alist-download/route.ts, page.tsx(前端)

### 3.3 站点标识 APP_SOURCE

默认 weilaimeng，用于 log-action, log-deny-event, track, alist-download 等文件的 source 字段。

### 3.4 deny-tracker source 默认值

source: input.source || process.env.APP_SOURCE || 'pan'

---

## 4. 架构全图

ECS 端口分配：
| 端口 | 服务 | Nginx Location |
|------|------|---------------|
| 3000 | Next.js(主站) | /pan/ |
| 3001 | Next.js(未来梦) | /wlm-api/ |
| 5244 | AList | /pdf-preview/ |
| 3100 | PostgREST | /db/ |
| 5432 | PostgreSQL | 内网 |

---

## 5. 数据库隔离策略

| 表 | 策略 | 说明 |
|---|------|------|
| wlm_bdpan_users | 表前缀 | 独立用户 |
| wlm_bdpan_settings | 表前缀 | 独立设置 |
| bdpan_action_logs | source列 | 共享可筛选 |
| bdpan_deny_events | source列 | 共享可筛选 |
| bdpan_risk_scores | 不隔离 | 跨站共享 |
| view_logs | page_source列 | 共享可筛选 |

迁移 SQL: ALTER TABLE ADD COLUMN source TEXT DEFAULT 'pan'; 加索引。

---

## 6. 部署方案

### 构建
cd /www/wwwroot/pan-wlm && sudo git pull && sudo npm install && sudo cp node_modules/@panzoom/panzoom/dist/panzoom.min.js public/pdfjs/ && sudo npm run build && sudo pm2 restart pan-wlm

PM2: pm2 start next --name pan-wlm -- start -p 3001

### Vercel
仓库 yhwlwl/pan-wlm, 域名 wlm.cdqzsta.tech
NEXT_PUBLIC_API_BASE=https://pan.tantantan.tech/wlm-api
NEXT_PUBLIC_FORCE_BASE_PATH=/sta/新媒体素材/可复用文件收集/未来梦扫描件
NEXT_PUBLIC_APP_SOURCE=weilaimeng

### ECS Nginx
location /wlm-api/ {
    proxy_pass http://127.0.0.1:3001/;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    add_header Access-Control-Allow-Origin *;
}

### ECS env
DB_TABLE_PREFIX=wlm_
FORCE_BASE_PATH=/sta/新媒体素材/可复用文件收集/未来梦扫描件
APP_SOURCE=weilaimeng
(其余与主站相同的密钥)

---

## 7. ECS 运维

```bash
cd /www/wwwroot/pan-wlm && sudo git stash && sudo git pull && sudo npm install && sudo cp node_modules/@panzoom/panzoom/dist/panzoom.min.js public/pdfjs/ && sudo npm run build && sudo pm2 restart pan-wlm

pm2 status | logs pan-wlm | restart pan-wlm
curl -I http://127.0.0.1:3001/api/global-settings
```

---

## 8. 已知限制

| # | 问题 | 改进方向 |
|---|------|----------|
| 1 | 密码明文 | bcrypt hash |
| 2 | 4340行单体 | 拆分组件 |
| 3 | deny-tracker硬编码表名 | 改为可配置前缀 |
| 4 | FORCE_BASE_PATH前后端各一份 | 仅后端配置 |
| 5 | Vercel冷启动 | 迁移ECS |
