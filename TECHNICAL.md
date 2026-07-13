# WLM-PAN 技术文档 — 未来梦 PDF 预览站

本文档面向接手项目的开发者和 AI，涵盖完整架构、与主站的关系、核心差异点、API 路由、权限系统、数据库隔离策略、管理后台及部署方案。

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
| 管理后台 | 无 | `/mg` 独立管理面板 |
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
- 管理后台：`/mg` 仅 WLM 部署（主站暂无）

### 数据流

```
用户 (wlm.cdqzsta.tech)
  -> Vercel CDN
  -> API https://pan.tantantan.tech/wlm-api/
  -> Nginx /wlm-api/ -> Next.js:3001
  -> wlm_bdpan_users / wlm_bdpan_settings (独立)
  -> bdpan_* 共享表 (source=weilaimeng)
  -> AList (FORCE_BASE_PATH 锁定目录)
```

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

```
Vercel (wlm.cdqzsta.tech)
  |
  +-- /mg          -> Next.js 管理后台
  +-- /api/*       -> ECS pan.tantantan.tech
  +-- /pdfjs/*     -> Vercel 静态文件
  
ECS (成都 2C2G)
  :3001 Next.js (未来梦 API)
    /wlm-api/  (通过 Nginx)
    
  :5244 AList (百度网盘桥接)
  :3100 PostgREST (数据库网关)
  :5432 PostgreSQL
```

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

## 6. 管理后台 `/mg`

独立于主站的管理面板，位于 `src/app/mg/`。

### 认证流程

```
用户访问 /mg
  ├─ 有 localStorage.BDPAN_TOKEN
  │    → fetch('/api/users') 验证
  │    ├─ 200 → 进管理后台（token 存 React state，内存）
  │    └─ 401 → 302 deny.tantantan.tech + 记录 deny 事件
  └─ 无 token → 登录页（用户名+密码）
```

### 侧边栏 10 板块

| # | 板块 | 文件 | 权限控制 |
|:-|------|------|---------|
| 1 | 总览 | sections/Overview.tsx | canView("mgOverview") |
| 2 | 下载明细 | sections/Downloads.tsx | canView("mgDownloads") |
| 3 | 访问日志 | sections/Visits.tsx | canView("mgVisits") |
| 4 | 操作日志 | sections/ActionLogs.tsx | canView("mgActionLogs") |
| 5 | 公告 | sections/Announcements.tsx | canView("mgAnnouncements") |
| 6 | 文件权限 | sections/FilePermissions.tsx | canView("mgFilePerms") |
| 7 | 用户管理 | sections/UserManagement.tsx | canView("mgUsers") |
| 8 | 风控管理 | sections/RiskControl.tsx | canView("mgRiskControl") |
| 9 | 风险标签 | sections/RiskLabelConfig.tsx | 超管(6) |
| 10 | 应急 | sections/Emergency.tsx | canView("mgEmergency") |
| 11 | 设置 | sections/Settings.tsx | canView("mgSettings") |

### 风险分级权限

每个操作标有风险等级(0-6)，用户每个板块配查看/修改最高级。

```
等级: 0=无 1=低 2=中 3=高 4=极高 5=紧急 6=超管
```

- `canView(sectionKey)` → sectionKey > 0 → 显示侧边栏
- `canModify(operationKey)` → 操作风险 ≤ 用户修改级 → 可操作
- 等级 6 = 硬编码仅 admin（manager 不可达）

存储：`bdpan_settings.permissions[username].mgPermissions`

### 文件结构

```
src/app/mg/
├── layout.tsx              # Token 校验 + 登录页
├── page.tsx                # 主页面（侧边栏 + tab 路由）
├── lib/
│   └── admin-context.tsx   # React Context：共享数据 + 权限检查
└── sections/
    ├── Sidebar.tsx          # 侧边栏导航
    ├── Overview.tsx         # 总览仪表盘
    ├── Downloads.tsx        # 下载明细
    ├── Visits.tsx           # 访问日志
    ├── ActionLogs.tsx       # 操作日志
    ├── RiskControl.tsx      # 风控管理
    ├── UserManagement.tsx   # 用户管理
    ├── FilePermissions.tsx  # 文件权限
    ├── Announcements.tsx    # 公告
    ├── RiskLabelConfig.tsx  # 风险标签配置
    ├── Emergency.tsx        # 应急
    └── Settings.tsx         # 设置
```

---

## 7. 风控系统（核心引擎）

`src/lib/deny-tracker.ts` — 评分、衰减、封禁、去重

### 配置化（可热更新）

所有硬编码参数已改为从 `bdpan_settings.denyTracking` 读取：

| 参数 | 默认 | 说明 |
|------|:---:|------|
| warnThreshold | 30 | 显示警告 |
| deviceBanThreshold | 50 | 设备封禁阈值 |
| ipBanThreshold | 70 | IP 封禁阈值 |
| decayWindowHours | 24 | 衰减窗口 |
| dedupWindowMinutes | 5 | 去重窗口 |
| devicePostBanScore | 40 | 解封后重置 |
| ipPostBanScore | 60 | 解封后重置 |
| scoreMap | 12 行为各分值 | 自定义加分 |
| firstBanMinutes | 10 | 首次封禁 |
| secondBanHours | 1 | 二次封禁 |
| thirdBanHours | 24 | 三次封禁 |
| banEscalationThreshold | 15 | 升级事件数 |

### 评分变化 (可配，默认)

```
nginx_db_token:30, nginx_sensitive_file:20, nginx_pdf_referer:10
nginx_well_known:15, nginx_unknown:10, api_ip_banned:25
api_auth_failed:5, api_login_failed:8, api_role_denied:10
api_permission_denied:5, api_file_rule_denied:5, api_all_items_denied:5
```

### iat 踢出机制

`_auth.ts` 中 `signToken()` 加 `iat: Date.now()`。设置 `tokenInvalidBefore` 后所有 `iat < invalidBefore` 且非 admin 的 token 被拒绝。

---

## 8. 公告系统

| 功能 | 存储 |
|------|------|
| 公告数组 | `bdpan_settings.value.announcements: Ann[]` |
| 单条内容 | content / active / targetAudience / displayLocation / scheduledAt |
| 显示位置 | login(登录页) / main(主页) / all(全部) |
| 目标受众 | all / guest(仅访客) / user(仅登录用户) |
| 定时发布 | scheduledAt 未到时不显示 |

---

## 9. 设置面板（10 张卡片）

管理员在 `/mg?tab=settings` 可配置：

| 卡片 | 内容 |
|------|------|
| 安全设置 | 修改管理员密码 |
| 全局设置 | 访客模式/AList 按钮/会话时长/刷新间隔 |
| 站点外观 | 标题/副标题/页脚/默认视图/预览上限 |
| 风控阈值 | 警告/设备/IP 封禁/解封重置分 |
| 风控评分规则 | 12 种行为分值/衰减窗口/去重窗口 |
| 阶梯封禁规则 | 首次/二次/三次时长/升级阈值 |
| 登录与频率限制 | 失败次数/窗口/并发会话 |
| 文件操作限制 | 批量下载上限/上传大小上限 |
| 数据保留 | 操作日志/Deny/访问日志保留天数 |
| 系统 | 服务端日志/API 地址/版本号 |

---

## 10. 应急面板

`/mg?tab=emergency`

| 操作 | 效果 |
|------|------|
| 全站维护模式 | 全量备份 6 表 → 快照 settings → 踢出+关访客+关下载 → 发维护公告 |
| 恢复运行 | 从快照恢复全部设置 → 清踢出标记 → 停公告 |
| 封禁所有在线 IP | 批量封 1h |

维护模式下 `/api/alist` 返回 403（`maintenanceMode && role !== 'admin'`）。

---

## 11. API 路由（关键）

| 路由 | 方法 | 用途 | 权限 |
|------|------|------|------|
| /api/admin-stats | GET | 统计/日志/IP | admin/manager(需权限) |
| /api/deny-stats | GET/POST | 风控数据/操作 | admin/manager |
| /api/users | GET/POST | 用户管理/设置 | admin |
| /api/file-permissions | GET/POST | 文件规则 | admin/controlFile |
| /api/mg-backup | POST/GET | 全量备份 | admin |
| /api/global-settings | GET | 公共设置 | 无限制 |
| /api/log-action | POST | 操作日志 | 有 token |
| /api/log-deny-event | POST | deny 事件 | 无限制 |
| /api/login | POST | 登录 | 无限制 |
| /api/check-risk | GET | 风险检查 | 有 token |
| /api/track | POST | 访问追踪 | 无限制 |
| /api/mg-sso | POST | SSO 授权 | 有 token（规划中）|

---

## 12. 部署方案

### 构建
```bash
cd /www/wwwroot/pan-wlm && sudo git pull && sudo npm install && \
sudo cp node_modules/@panzoom/panzoom/dist/panzoom.min.js public/pdfjs/ && \
sudo npm run build && sudo pm2 restart pan-wlm
```

PM2: `pm2 start next --name pan-wlm -- start -p 3001`

### Vercel 环境变量
```
NEXT_PUBLIC_API_BASE=https://pan.tantantan.tech/wlm-api
NEXT_PUBLIC_ALIST_URL=https://pan.tantantan.tech/
NEXT_PUBLIC_SUPABASE_URL=https://pan.tantantan.tech/db
NEXT_PUBLIC_FORCE_BASE_PATH=/sta/新媒体素材/可复用文件收集/未来梦扫描件
NEXT_PUBLIC_APP_SOURCE=weilaimeng
```

### ECS Nginx
```nginx
location /wlm-api/pdfjs/ {
    alias /www/wwwroot/pan-wlm/public/pdfjs/;
    add_header Access-Control-Allow-Origin *;
    add_header Cache-Control "public, max-age=31536000, immutable";
}
location /wlm-api/ {
    proxy_pass http://127.0.0.1:3001/;
    add_header Access-Control-Allow-Origin *;
}
```

### ECS env
```
DB_TABLE_PREFIX=wlm_
FORCE_BASE_PATH=/sta/新媒体素材/可复用文件收集/未来梦扫描件
APP_SOURCE=weilaimeng
ADMIN_TOKEN_SECRET=***
MG_TOKEN_SECRET=***  (规划中)
```

---

## 13. ECS 运维

```bash
# 构建部署
cd /www/wwwroot/pan-wlm && sudo git pull && sudo npm install && \
sudo cp node_modules/@panzoom/panzoom/dist/panzoom.min.js public/pdfjs/ && \
sudo npm run build && sudo pm2 restart pan-wlm

# 只改 viewer.html（静态文件）则无需构建
# Nginx 直接读磁盘

# PM2
pm2 status
pm2 logs pan-wlm
pm2 restart pan-wlm

# 健康检查
curl -I http://127.0.0.1:3001/api/global-settings
curl -I https://pan.tantantan.tech/wlm-api/api/global-settings
```

---

## 14. 已知限制

| # | 问题 | 改进方向 |
|---|------|----------|
| 1 | 密码明文 | bcrypt hash |
| 2 | 4500行page.tsx单体 | 拆分组件 |
| 3 | deny-tracker硬编码表名 | 改为可配置前缀 |
| 4 | FORCE_BASE_PATH前后端各一份 | 仅后端配置 |
| 5 | Vercel冷启动 | 迁移ECS |
| 6 | page.tsx本地UserPermissions与lib/users.ts重复 | 统一引用 |
| 7 | deny.tantantan.tech 静态页 | 合并到项目内 |
