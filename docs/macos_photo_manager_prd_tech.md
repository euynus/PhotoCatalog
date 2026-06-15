# macOS 照片原件管理软件需求与技术设计文档

版本：v0.1  
定位：类似 Lightroom Library 模块的照片管理软件，不做照片编辑，专注于原件管理、检索、组织、预览、元数据、备份与导出。  
默认产品名：PhotoCatalog Mac（占位名，可替换）  
目标平台：macOS 桌面端，Swift 原生应用。

---

## 1. 产品目标

### 1.1 一句话定位

为摄影师、内容创作者和重度照片用户提供一个本地优先、快速、可靠、非破坏式的 macOS 照片原件管理工具。

### 1.2 核心价值

1. 管理大量照片原件，包括 JPEG、HEIC、PNG、TIFF、DNG、常见 RAW。
2. 不修改原始文件，所有评分、标签、相册、筛选条件默认写入本地目录库数据库。
3. 支持引用式管理和托管式导入两种模式。
4. 提供快速缩略图浏览、元数据检索、关键词、评分、颜色标签、智能相册、文件夹监听。
5. 支持缺失文件检测、重复文件检测、目录库备份与恢复。

### 1.3 明确不做

MVP 不做以下能力：

1. 不做曝光、色彩、裁剪、滤镜等照片编辑。
2. 不做云端同步和多人协作。
3. 不做移动端。
4. 不直接替代 Apple Photos 系统图库。
5. 不默认写回原图 EXIF/IPTC/XMP，避免破坏原件；可在后续版本提供“写入 XMP sidecar”的可选能力。

---

## 2. 用户画像

### 2.1 摄影爱好者

- 照片量：1 万到 20 万张。
- 文件类型：JPEG、HEIC、DNG、相机 RAW。
- 需求：导入、分类、按时间/地点/相机/评分查找、删除废片、导出精选照片。

### 2.2 职业摄影师

- 照片量：10 万到 100 万张。
- 文件类型：大量 RAW + JPEG。
- 需求：按项目/客户/拍摄日期管理；快速筛选；关键词体系；备份状态；原件位置可追踪。

### 2.3 内容创作者/设计师

- 照片量：几千到几十万张。
- 需求：快速找素材；按颜色标签/关键词/文件夹管理；拖放到其他应用；导出指定尺寸或原件复制。

---

## 3. 核心概念定义

| 概念 | 定义 |
|---|---|
| 目录库 Catalog | 应用的本地数据库和缓存包，记录照片索引、标签、相册、缩略图、预览图、任务状态。 |
| 原件 Original | 用户磁盘中的照片文件，不做破坏性修改。 |
| 引用式管理 Referenced | 只索引用户已有文件夹中的照片，原件仍在原路径。 |
| 托管式管理 Managed | 导入时复制照片到应用目录库指定 Originals 文件夹。 |
| 资产 Asset | 应用中表示一张照片或一个媒体文件的逻辑记录。 |
| 缩略图 Thumbnail | 用于网格展示的小图缓存。 |
| 预览图 Preview | 用于单张查看/比较的中大尺寸缓存。 |
| Sidecar | 与原图同名或关联的 XMP 文件，用于跨软件交换元数据。 |
| 智能相册 Smart Album | 基于规则自动生成的动态集合。 |

---

## 4. 产品范围与版本规划

### 4.1 MVP / v1.0 必须完成

1. 创建、打开、关闭本地目录库。
2. 添加照片源文件夹，获得用户授权后递归扫描。
3. 引用式导入照片；托管式导入可作为 v1.0 后半部分或 v1.1。
4. 读取基础元数据：文件名、路径、大小、修改时间、拍摄时间、宽高、方向、相机、镜头、ISO、光圈、快门、焦距、GPS。
5. 生成并缓存缩略图和预览图。
6. 网格浏览、单张查看、基础比较视图。
7. 评分、旗标、颜色标签、关键词、标题、说明。
8. 普通相册、智能相册。
9. 搜索、筛选、排序。
10. 文件缺失检测、重新定位。
11. 精确重复检测。
12. 目录库备份与恢复。
13. 文件夹变化监听与增量扫描。
14. 导出/复制原件与元数据。

### 4.2 v1.1 建议增加

1. 托管式导入到目录库 Originals。
2. XMP sidecar 读写。
3. 更完整的 RAW 兼容策略。
4. 相册内自定义排序。
5. 批量重命名。
6. 批量修改拍摄时间/时区。
7. 地图视图。
8. 导出预设。

### 4.3 v2.0 建议增加

1. 人脸检测与人物集合。
2. 相似照片/连拍分组。
3. Apple Photos 导入桥接。
4. 自动标签/场景识别。
5. NAS/外置盘更完整的离线卷管理。
6. 插件系统。

---

## 5. 关键用户流程

### 5.1 首次使用

1. 用户打开应用。
2. 应用提示创建目录库：默认位置为 `~/Pictures/PhotoCatalog Library.photolibrary`。
3. 用户选择“添加照片文件夹”。
4. 系统弹出文件夹选择器，用户授权。
5. 应用保存安全书签，开始扫描。
6. 首页显示导入进度、已发现数量、成功/失败数量。
7. 缩略图逐步出现，用户可立即浏览已完成部分。

### 5.2 日常管理

1. 用户打开目录库。
2. 应用恢复授权文件夹访问。
3. 后台检查文件变化和未完成任务。
4. 用户在网格中筛选“未评分 + 最近导入”。
5. 用户快速打星、打旗标、加关键词。
6. 用户把精选照片加入相册或导出给客户。

### 5.3 外置硬盘离线

1. 用户打开目录库，但某个源文件夹所在磁盘不在线。
2. 资产显示“离线”徽标，仍可看到缓存缩略图和预览图。
3. 用户可筛选“缺失/离线照片”。
4. 磁盘重新连接后应用自动恢复可访问状态。

### 5.4 文件被移动

1. 应用发现原路径不可达。
2. 资产标记为 missing。
3. 用户点击“重新定位”。
4. 用户选择新文件夹或新文件。
5. 应用按文件名、大小、拍摄时间、哈希匹配并修复路径。

---

## 6. 功能需求

### 6.1 目录库管理

| ID | 优先级 | 需求 | 验收标准 |
|---|---|---|---|
| CAT-001 | P0 | 创建新的目录库包 | 能在用户指定位置创建 `.photolibrary` 包，包含数据库、缓存、配置、日志目录。 |
| CAT-002 | P0 | 打开已有目录库 | 双击或应用内选择可打开；版本不兼容时给出明确提示。 |
| CAT-003 | P0 | 目录库迁移 | 数据库 schema 版本升级自动执行迁移；失败时回滚并保留备份。 |
| CAT-004 | P1 | 最近目录库列表 | 启动页显示最近打开的目录库。 |
| CAT-005 | P1 | 目录库健康检查 | 检查数据库、缩略图缓存、源文件夹授权、缺失文件。 |

### 6.2 文件夹授权与源管理

| ID | 优先级 | 需求 | 验收标准 |
|---|---|---|---|
| SRC-001 | P0 | 添加源文件夹 | 通过系统选择面板选择文件夹，支持多个源。 |
| SRC-002 | P0 | 保存持久访问权限 | 应用重启后无需用户再次选择即可访问已授权源。 |
| SRC-003 | P0 | 源文件夹状态 | 显示在线、离线、权限失效、扫描中、错误。 |
| SRC-004 | P1 | 移除源 | 移除索引但不删除原件；托管源另行确认。 |
| SRC-005 | P1 | 重新授权 | 权限失效时引导用户重新选择同一文件夹。 |
| SRC-006 | P2 | 源优先级 | 用户可设置哪些源优先索引/缩略图。 |

### 6.3 扫描与导入

| ID | 优先级 | 需求 | 验收标准 |
|---|---|---|---|
| IMP-001 | P0 | 递归扫描源文件夹 | 可发现支持的图片文件；忽略隐藏文件、应用缓存、系统包。 |
| IMP-002 | P0 | 增量扫描 | 文件新增、删除、修改后只处理变化部分。 |
| IMP-003 | P0 | 可暂停/恢复 | 大批量导入时可暂停；重启应用后继续未完成任务。 |
| IMP-004 | P0 | 导入进度 | 显示已扫描、待处理、成功、失败、跳过数量。 |
| IMP-005 | P0 | 错误列表 | 支持查看失败文件、失败原因、重试。 |
| IMP-006 | P1 | 托管式导入 | 复制原件到目录库 Originals，按日期或自定义规则归档。 |
| IMP-007 | P1 | 导入去重策略 | 精确重复文件可跳过、保留、加入重复组。 |
| IMP-008 | P1 | 导入后动作 | 可自动加关键词、加入相册、设置颜色标签。 |

### 6.4 原件管理

| ID | 优先级 | 需求 | 验收标准 |
|---|---|---|---|
| ORG-001 | P0 | 非破坏式管理 | 默认只读原件；评分、关键词等写入目录库。 |
| ORG-002 | P0 | 在 Finder 中显示 | 选中照片后可打开 Finder 定位原件。 |
| ORG-003 | P0 | 缺失检测 | 原文件不存在或无权限时显示 missing/offline。 |
| ORG-004 | P1 | 重新定位原件 | 用户选择新路径后自动匹配并修复引用。 |
| ORG-005 | P1 | 移动/复制原件 | 可由应用发起移动/复制，执行前二次确认。 |
| ORG-006 | P1 | 删除策略 | 从目录库移除和移到废纸篓分离；默认不删除磁盘原件。 |
| ORG-007 | P2 | 卷管理 | 外置盘按 volume UUID 或文件系统标识识别。 |

### 6.5 元数据

| ID | 优先级 | 需求 | 验收标准 |
|---|---|---|---|
| META-001 | P0 | 基础文件元数据 | 文件名、扩展名、路径、大小、mtime、ctime。 |
| META-002 | P0 | 图片元数据 | 宽高、方向、色彩空间、ICC 是否存在。 |
| META-003 | P0 | EXIF 拍摄信息 | 拍摄时间、相机、镜头、焦距、光圈、快门、ISO。 |
| META-004 | P0 | GPS | 经纬度、海拔可读取并用于筛选。 |
| META-005 | P0 | 用户元数据 | 评分、旗标、颜色标签、关键词、标题、说明。 |
| META-006 | P1 | IPTC/XMP 读取 | 读取标题、说明、版权、作者、关键词。 |
| META-007 | P1 | XMP sidecar 写入 | 用户开启后写入 `.xmp`，不直接改原图。 |
| META-008 | P1 | 批量修改 | 批量修改评分、关键词、日期、标题、说明。 |
| META-009 | P2 | MakerNotes | 扩展读取厂商私有信息，仅展示不用于核心逻辑。 |

### 6.6 缩略图与预览

| ID | 优先级 | 需求 | 验收标准 |
|---|---|---|---|
| THM-001 | P0 | 缩略图生成 | 导入后生成 256px、512px 缩略图。 |
| THM-002 | P0 | 预览图生成 | 可配置生成 1600px 或 2048px 长边预览图。 |
| THM-003 | P0 | 按需生成 | 滚动可见区域优先生成；后台补齐。 |
| THM-004 | P0 | 缓存失效 | 文件修改后自动重新生成缓存。 |
| THM-005 | P1 | 离线可预览 | 原件离线时仍可查看已缓存缩略图/预览图。 |
| THM-006 | P1 | 缓存清理 | 用户可清理、重建、限制缓存大小。 |

### 6.7 浏览与查看

| ID | 优先级 | 需求 | 验收标准 |
|---|---|---|---|
| UI-001 | P0 | 网格视图 | 支持上万照片流畅滚动、可调缩略图大小。 |
| UI-002 | P0 | 单张查看 | 双击进入 Loupe，显示大图和基础信息。 |
| UI-003 | P0 | 详情面板 | 展示文件、EXIF、用户元数据、关键词、路径。 |
| UI-004 | P0 | 快捷键 | 1-5 打星、0 清除评分、P/X/U 旗标、方向键切换。 |
| UI-005 | P1 | 比较视图 | 支持 2 张到 4 张照片并排比较。 |
| UI-006 | P1 | 胶片带 | 单张查看下方显示当前集合的照片。 |
| UI-007 | P1 | 批量选择 | 支持 Shift/Command 多选、全选、反选。 |
| UI-008 | P2 | 地图视图 | 有 GPS 的照片显示在地图上。 |

### 6.8 组织体系

| ID | 优先级 | 需求 | 验收标准 |
|---|---|---|---|
| ORGZ-001 | P0 | 文件夹树 | 按源文件夹结构显示。 |
| ORGZ-002 | P0 | 普通相册 | 用户手动添加/移除照片，不影响磁盘文件。 |
| ORGZ-003 | P0 | 智能相册 | 基于规则动态显示，例如评分>=4 且拍摄日期在本月。 |
| ORGZ-004 | P0 | 关键词 | 支持层级关键词、批量添加、自动补全。 |
| ORGZ-005 | P1 | 堆栈/分组 | 支持把相似或同一场景照片折叠为堆栈。 |
| ORGZ-006 | P1 | 收藏夹 | 常用相册、文件夹可固定在侧边栏。 |
| ORGZ-007 | P2 | 项目/客户 | 面向职业摄影师的项目维度。 |

### 6.9 搜索、筛选、排序

| ID | 优先级 | 需求 | 验收标准 |
|---|---|---|---|
| SRCH-001 | P0 | 文本搜索 | 搜索文件名、关键词、标题、说明、相机、镜头。 |
| SRCH-002 | P0 | 条件筛选 | 支持评分、旗标、颜色、日期、文件类型、相机、镜头、GPS、缺失状态。 |
| SRCH-003 | P0 | 排序 | 支持拍摄时间、导入时间、文件名、评分、文件大小。 |
| SRCH-004 | P1 | 高级查询构建器 | 多条件 AND/OR 组合。 |
| SRCH-005 | P1 | 保存筛选 | 当前筛选可保存为智能相册。 |

### 6.10 重复与相似照片

| ID | 优先级 | 需求 | 验收标准 |
|---|---|---|---|
| DUP-001 | P0 | 精确重复检测 | 基于文件大小 + 内容哈希识别完全相同文件。 |
| DUP-002 | P1 | 疑似重复 | 基于拍摄时间、文件名、尺寸、quick hash 初筛。 |
| DUP-003 | P2 | 相似照片 | 使用感知哈希或图像特征向量，按相似度聚类。 |
| DUP-004 | P1 | 重复处理 | 用户可保留一个、移除目录库记录、移到废纸篓。 |

### 6.11 导出

| ID | 优先级 | 需求 | 验收标准 |
|---|---|---|---|
| EXP-001 | P0 | 复制原件 | 将选中照片原件复制到目标文件夹。 |
| EXP-002 | P1 | 导出目录结构 | 可按日期、相册、源文件夹结构导出。 |
| EXP-003 | P1 | 导出元数据 | 可生成 CSV/JSON/XMP sidecar。 |
| EXP-004 | P2 | 导出预览图 | 不做编辑，但可导出缓存预览图用于轻量分享。 |

### 6.12 备份与恢复

| ID | 优先级 | 需求 | 验收标准 |
|---|---|---|---|
| BAK-001 | P0 | 目录库备份 | 备份数据库、配置、用户元数据，不强制备份原件。 |
| BAK-002 | P0 | 自动备份 | 可配置每天/每周启动时备份。 |
| BAK-003 | P0 | 恢复 | 可从备份恢复目录库。 |
| BAK-004 | P1 | 缩略图重建 | 缓存损坏时可删除并重建。 |
| BAK-005 | P1 | 完整性检查 | 校验数据库、任务队列、缩略图引用、原件引用。 |

---

## 7. 非功能需求

### 7.1 性能目标

| 场景 | 目标 |
|---|---|
| 打开 10 万照片目录库 | 3 秒内显示主窗口和侧边栏，网格异步加载。 |
| 网格滚动 | 常规 Mac 上保持流畅，不因缩略图生成阻塞主线程。 |
| 初次扫描 | 每秒至少枚举数百到数千文件，具体取决于磁盘。 |
| 缩略图显示 | 已缓存缩略图在 100ms 内可显示；未缓存先显示占位图。 |
| 搜索 | 常用筛选在 200ms 到 500ms 内返回首屏结果。 |
| 内存 | 浏览 10 万照片时常规状态小于 1GB，极端缩略图预取不超过用户设置上限。 |

### 7.2 稳定性

1. 所有数据库写入走事务。
2. 长任务可恢复，任务状态持久化。
3. 应用崩溃后重启能继续未完成导入。
4. 原件删除、移动、重命名需要明确用户确认。
5. 目录库升级前自动备份数据库。

### 7.3 隐私与安全

1. 本地优先，默认不上传任何照片和元数据。
2. 只访问用户授权的文件夹。
3. 保存安全书签用于重启后访问。
4. 错误日志不记录完整照片内容，不上传日志。
5. 可提供“清除最近目录库/清除缓存/清除授权”的隐私选项。

### 7.4 可维护性

1. 业务逻辑与 UI 分离。
2. 数据库 schema 使用显式 migration。
3. 后台任务有统一 Job 表和重试策略。
4. 对第三方依赖封装接口，避免散落在 UI 层。

---

## 8. 推荐技术栈

### 8.1 总体选择

| 层 | 推荐 |
|---|---|
| 语言 | Swift |
| UI | SwiftUI + AppKit 混合。复杂网格优先 NSCollectionView，其他界面 SwiftUI。 |
| 数据库 | SQLite + GRDB.swift；备选 Core Data。 |
| 缩略图 | Quick Look Thumbnailing 优先，Image I/O fallback。 |
| 元数据 | Image I/O 优先；XMP sidecar 自行 XML 解析；高级 MakerNotes 可选 ExifTool 或 LibRaw。 |
| 文件访问 | App Sandbox + security-scoped bookmark。 |
| 文件变化 | FSEvents。 |
| 并发 | Swift Concurrency、actor、OperationQueue。 |
| 搜索 | SQLite FTS5 + 普通索引。 |
| 测试 | XCTest、临时目录集成测试、性能基准测试。 |

### 8.2 为什么选 SQLite + GRDB

1. 照片管理的核心是大量结构化筛选、排序、FTS 搜索和批量更新。
2. SQLite 单文件便于备份、迁移和诊断。
3. GRDB 提供 Swift 友好的 SQLite 访问、migration、查询、事务、观察能力。
4. Core Data 也可行，但复杂 SQL、FTS、批量性能调优不如直接使用 SQLite 透明。
5. SwiftData 更适合新项目和 SwiftUI 集成，但如果要支持 macOS 13 或更早，或需要非常可控的大规模查询，当前不作为首选。

---

## 9. 目录库文件结构

建议把目录库做成 macOS package：

```text
PhotoCatalog Library.photolibrary/
  catalog.sqlite
  catalog.sqlite-wal
  catalog.sqlite-shm
  manifest.json
  Backups/
    catalog-2026-06-14-120000.sqlite
  Cache/
    Thumbnails/
      256/
      512/
    Previews/
      2048/
  Originals/                 # 托管式导入才使用
    2026/
      06/
        14/
  Logs/
    app.log
    import.log
  Temp/
```

`manifest.json` 示例：

```json
{
  "libraryVersion": 1,
  "schemaVersion": 1,
  "createdAt": "2026-06-14T00:00:00Z",
  "appBuild": "1.0.0",
  "uuid": "D9F08C4E-..."
}
```

---

## 10. 数据库设计

### 10.1 表概览

| 表 | 用途 |
|---|---|
| source_roots | 用户授权的源文件夹。 |
| assets | 照片资产主表。 |
| asset_metadata | 可扩展元数据。 |
| keywords | 层级关键词。 |
| asset_keywords | 资产与关键词多对多。 |
| albums | 普通相册、智能相册、文件夹集合。 |
| album_assets | 普通相册与资产关系。 |
| smart_album_rules | 智能相册规则 JSON。 |
| thumbnails | 缩略图/预览图缓存记录。 |
| import_sessions | 导入会话。 |
| jobs | 后台任务队列。 |
| duplicate_groups | 重复文件组。 |
| duplicate_items | 重复文件项。 |
| asset_search | FTS5 全文搜索表。 |
| schema_migrations | 数据库迁移记录。 |

### 10.2 SQL DDL 草案

```sql
CREATE TABLE source_roots (
  id TEXT PRIMARY KEY,
  display_name TEXT NOT NULL,
  path_hint TEXT NOT NULL,
  bookmark_data BLOB NOT NULL,
  access_mode TEXT NOT NULL DEFAULT 'readOnly',
  management_mode TEXT NOT NULL DEFAULT 'referenced', -- referenced / managed
  volume_uuid TEXT,
  is_enabled INTEGER NOT NULL DEFAULT 1,
  status TEXT NOT NULL DEFAULT 'unknown', -- online/offline/permissionLost/scanning/error
  last_full_scan_at TEXT,
  last_event_id INTEGER,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE assets (
  id TEXT PRIMARY KEY,
  root_id TEXT REFERENCES source_roots(id) ON DELETE SET NULL,
  relative_path TEXT,
  filename TEXT NOT NULL,
  file_extension TEXT,
  uti TEXT,
  media_type TEXT NOT NULL DEFAULT 'image',
  management_mode TEXT NOT NULL DEFAULT 'referenced',
  original_path_hint TEXT NOT NULL,

  file_size INTEGER,
  file_mtime TEXT,
  file_ctime TEXT,
  inode TEXT,
  content_hash TEXT,
  quick_hash TEXT,

  capture_date TEXT,
  capture_date_source TEXT,
  timezone_offset INTEGER,
  width INTEGER,
  height INTEGER,
  orientation INTEGER,
  color_space TEXT,
  has_icc_profile INTEGER DEFAULT 0,

  camera_make TEXT,
  camera_model TEXT,
  lens_model TEXT,
  focal_length REAL,
  aperture REAL,
  shutter_speed TEXT,
  iso INTEGER,
  gps_latitude REAL,
  gps_longitude REAL,
  gps_altitude REAL,

  rating INTEGER NOT NULL DEFAULT 0 CHECK (rating BETWEEN 0 AND 5),
  pick_flag TEXT NOT NULL DEFAULT 'none', -- none/pick/reject
  color_label TEXT,
  title TEXT,
  caption TEXT,
  copyright TEXT,

  is_missing INTEGER NOT NULL DEFAULT 0,
  is_offline INTEGER NOT NULL DEFAULT 0,
  is_deleted INTEGER NOT NULL DEFAULT 0,
  stack_id TEXT,

  imported_at TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,

  UNIQUE(root_id, relative_path)
);

CREATE INDEX idx_assets_capture_date ON assets(capture_date);
CREATE INDEX idx_assets_imported_at ON assets(imported_at);
CREATE INDEX idx_assets_rating ON assets(rating);
CREATE INDEX idx_assets_camera ON assets(camera_make, camera_model);
CREATE INDEX idx_assets_hash ON assets(content_hash);
CREATE INDEX idx_assets_missing ON assets(is_missing, is_offline);

CREATE TABLE asset_metadata (
  asset_id TEXT NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
  namespace TEXT NOT NULL,
  key TEXT NOT NULL,
  value TEXT,
  value_type TEXT NOT NULL DEFAULT 'string',
  PRIMARY KEY(asset_id, namespace, key)
);

CREATE TABLE keywords (
  id TEXT PRIMARY KEY,
  parent_id TEXT REFERENCES keywords(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  normalized_name TEXT NOT NULL,
  path TEXT NOT NULL,
  sort_order INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE(parent_id, normalized_name)
);

CREATE TABLE asset_keywords (
  asset_id TEXT NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
  keyword_id TEXT NOT NULL REFERENCES keywords(id) ON DELETE CASCADE,
  created_at TEXT NOT NULL,
  PRIMARY KEY(asset_id, keyword_id)
);

CREATE TABLE albums (
  id TEXT PRIMARY KEY,
  parent_id TEXT REFERENCES albums(id) ON DELETE CASCADE,
  type TEXT NOT NULL, -- album/smart/folder
  name TEXT NOT NULL,
  sort_order INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE album_assets (
  album_id TEXT NOT NULL REFERENCES albums(id) ON DELETE CASCADE,
  asset_id TEXT NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
  position INTEGER NOT NULL DEFAULT 0,
  added_at TEXT NOT NULL,
  PRIMARY KEY(album_id, asset_id)
);

CREATE TABLE smart_album_rules (
  album_id TEXT PRIMARY KEY REFERENCES albums(id) ON DELETE CASCADE,
  rule_json TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE thumbnails (
  asset_id TEXT NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
  kind TEXT NOT NULL, -- thumb256/thumb512/preview2048
  cache_path TEXT NOT NULL,
  width INTEGER NOT NULL,
  height INTEGER NOT NULL,
  format TEXT NOT NULL,
  source_signature TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'ready',
  generated_at TEXT NOT NULL,
  PRIMARY KEY(asset_id, kind)
);

CREATE TABLE import_sessions (
  id TEXT PRIMARY KEY,
  root_id TEXT REFERENCES source_roots(id) ON DELETE SET NULL,
  state TEXT NOT NULL, -- running/paused/completed/failed/cancelled
  total_count INTEGER NOT NULL DEFAULT 0,
  imported_count INTEGER NOT NULL DEFAULT 0,
  skipped_count INTEGER NOT NULL DEFAULT 0,
  failed_count INTEGER NOT NULL DEFAULT 0,
  started_at TEXT NOT NULL,
  finished_at TEXT,
  error_message TEXT
);

CREATE TABLE jobs (
  id TEXT PRIMARY KEY,
  type TEXT NOT NULL, -- scan/metadata/thumbnail/hash/fts/backup
  priority INTEGER NOT NULL DEFAULT 0,
  state TEXT NOT NULL DEFAULT 'pending', -- pending/running/succeeded/failed/cancelled
  payload_json TEXT NOT NULL,
  attempts INTEGER NOT NULL DEFAULT 0,
  max_attempts INTEGER NOT NULL DEFAULT 3,
  locked_at TEXT,
  last_error TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE duplicate_groups (
  id TEXT PRIMARY KEY,
  method TEXT NOT NULL, -- contentHash/perceptualHash/featurePrint
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE duplicate_items (
  group_id TEXT NOT NULL REFERENCES duplicate_groups(id) ON DELETE CASCADE,
  asset_id TEXT NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
  score REAL NOT NULL DEFAULT 1.0,
  PRIMARY KEY(group_id, asset_id)
);

CREATE VIRTUAL TABLE asset_search USING fts5(
  asset_id UNINDEXED,
  filename,
  title,
  caption,
  keywords,
  camera,
  lens,
  tokenize = 'unicode61'
);
```

### 10.3 智能相册规则 JSON

```json
{
  "operator": "and",
  "conditions": [
    { "field": "rating", "op": ">=", "value": 4 },
    { "field": "capture_date", "op": "between", "value": ["2026-01-01", "2026-12-31"] },
    { "field": "keywords", "op": "contains", "value": "旅行" },
    { "field": "is_missing", "op": "=", "value": false }
  ],
  "sort": [{ "field": "capture_date", "direction": "desc" }]
}
```

---

## 11. 技术架构

### 11.1 分层

```text
App
 ├── Presentation
 │    ├── SwiftUI: Sidebar, Inspector, Search, Settings
 │    └── AppKit: HighPerformanceGridView(NSCollectionView)
 ├── Application
 │    ├── UseCases: Import, Scan, Search, Rate, Keyword, Export
 │    ├── JobScheduler
 │    └── AppState / Navigation
 ├── Domain
 │    ├── Asset, Album, Keyword, SourceRoot
 │    ├── SmartAlbumRule
 │    └── Errors
 ├── Infrastructure
 │    ├── Database: GRDB migrations/repositories
 │    ├── FileAccess: security-scoped bookmarks
 │    ├── FileScanner: enumeration + FSEvents
 │    ├── MetadataReader: ImageIO/XMP/RAW adapters
 │    ├── ThumbnailService: QuickLook/ImageIO
 │    ├── HashService
 │    └── BackupService
 └── Shared
      ├── Logging
      ├── LRUCache
      └── Utilities
```

### 11.2 模块职责

| 模块 | 职责 |
|---|---|
| CatalogService | 创建/打开/关闭目录库，版本检查，迁移，备份。 |
| SourceRootService | 添加、移除、恢复授权源文件夹。 |
| FileAccessService | 创建和解析 security-scoped bookmark。 |
| ScannerService | 枚举源文件夹，识别支持文件，生成任务。 |
| MetadataService | 读取 EXIF/IPTC/XMP/文件属性。 |
| ThumbnailService | 生成缩略图和预览图，维护缓存。 |
| AssetRepository | 资产 CRUD、批量更新、查询。 |
| SearchService | 普通筛选、FTS、智能相册查询。 |
| JobScheduler | 任务调度、重试、恢复、优先级。 |
| FileWatcherService | 监听文件夹变化，触发增量扫描。 |
| DuplicateService | 计算哈希、生成重复组。 |
| ExportService | 复制原件、导出元数据、导出预览。 |

---

## 12. 关键实现细节

### 12.1 文件夹授权

流程：

1. 使用 `NSOpenPanel` 让用户选择文件夹。
2. 对返回 URL 创建 security-scoped bookmark。
3. 将 bookmark data 保存到 `source_roots.bookmark_data`。
4. 应用启动或扫描前解析 bookmark。
5. 调用 `startAccessingSecurityScopedResource()`。
6. 操作结束后调用 `stopAccessingSecurityScopedResource()`。
7. bookmark stale 时提示重新授权。

Swift 示例：

```swift
final class FileAccessService {
    func createBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    func resolveBookmark(_ data: Data) throws -> (url: URL, isStale: Bool) {
        var stale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        return (url, stale)
    }

    func withAccess<T>(to url: URL, _ work: () throws -> T) throws -> T {
        let ok = url.startAccessingSecurityScopedResource()
        defer {
            if ok { url.stopAccessingSecurityScopedResource() }
        }
        return try work()
    }
}
```

### 12.2 文件扫描

扫描规则：

1. 使用 `FileManager.enumerator` 递归枚举。
2. 跳过：隐藏文件、`.photolibrary`、`.app`、`.pkg`、`.lrdata`、缓存目录、系统目录。
3. 使用 `UniformTypeIdentifiers` 判断是否为图片或 RAW。
4. 每发现一个候选文件，生成 metadata job 和 thumbnail job。
5. 使用批量事务写入 assets，避免单文件一次写库。
6. 每次扫描记录 session，支持暂停/恢复。

伪代码：

```swift
func scan(root: SourceRoot) async throws {
    try fileAccess.withAccess(to: root.url) {
        let enumerator = FileManager.default.enumerator(
            at: root.url,
            includingPropertiesForKeys: [.isRegularFileKey, .isHiddenKey, .contentModificationDateKey, .fileSizeKey, .typeIdentifierKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )

        var batch: [DiscoveredFile] = []
        for case let fileURL as URL in enumerator ?? [] {
            guard isSupportedImage(fileURL) else { continue }
            batch.append(DiscoveredFile(url: fileURL, root: root))
            if batch.count >= 500 {
                try assetRepository.upsertDiscoveredFiles(batch)
                batch.removeAll(keepingCapacity: true)
            }
        }
        if !batch.isEmpty {
            try assetRepository.upsertDiscoveredFiles(batch)
        }
    }
}
```

### 12.3 支持文件类型

MVP 建议：

- JPEG / JPG
- HEIC / HEIF
- PNG
- TIFF / TIF
- DNG
- 常见 RAW：CR2、CR3、NEF、ARW、RAF、ORF、RW2 等，是否能预览取决于系统或可选 RAW 库。

判断策略：

1. 先用 UTType 判断是否 conforms to image 或 raw image。
2. 再用扩展名 fallback。
3. 导入失败不阻塞整个扫描，记录错误。

### 12.4 元数据读取

优先级：

1. 文件系统属性：大小、mtime、路径、volume。
2. Image I/O：宽高、方向、EXIF、TIFF、GPS、ICC。
3. XMP sidecar：标题、说明、关键词、版权、评分。
4. 可选增强：ExifTool 或 LibRaw 读取更广泛的厂商字段和 RAW 嵌入预览。

拍摄时间优先级：

1. EXIF DateTimeOriginal。
2. EXIF CreateDate。
3. XMP CreateDate。
4. 文件创建时间。
5. 文件修改时间。

注意：拍摄时间要保存来源字段 `capture_date_source`，方便用户排查。

### 12.5 缩略图生成

策略：

1. 网格优先 256px。
2. Retina/大网格使用 512px。
3. 单张查看使用 2048px 预览。
4. 原件离线时使用缓存。
5. 缩略图路径用 `asset_id` 或内容哈希分片，避免单目录文件过多。

缓存路径建议：

```text
Cache/Thumbnails/256/ab/cd/<asset_id>.jpg
Cache/Thumbnails/512/ab/cd/<asset_id>.jpg
Cache/Previews/2048/ab/cd/<asset_id>.jpg
```

Quick Look 示例：

```swift
import QuickLookThumbnailing

final class ThumbnailService {
    func generate(url: URL, size: CGSize, scale: CGFloat, outputURL: URL) async throws {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: size,
            scale: scale,
            representationTypes: [.thumbnail]
        )

        try await withCheckedThrowingContinuation { continuation in
            QLThumbnailGenerator.shared.saveBestRepresentation(
                for: request,
                to: outputURL,
                as: .jpg
            ) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: ()) }
            }
        }
    }
}
```

Image I/O fallback 思路：

```swift
func createThumbnailWithImageIO(input: URL, maxPixelSize: Int) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(input as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceShouldCacheImmediately: false,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
}
```

### 12.6 UI 网格性能

建议实现：

1. 网格用 `NSCollectionView`，外层用 `NSViewRepresentable` 嵌入 SwiftUI。
2. 数据源使用分页查询或 diffable data source。
3. cell 只持有 asset id 和当前缩略图状态。
4. 可见区域优先请求缩略图；不可见任务降级或取消。
5. `NSCache` 做内存 LRU；磁盘缓存作为二级缓存。
6. 滚动中不做昂贵布局计算。

Cell 状态：

- placeholder
- loading
- ready(image)
- failed
- missing/offline badge
- raw/jpeg/video badge
- rating/color/pick badges

### 12.7 搜索实现

普通筛选走 SQL where：

```sql
SELECT * FROM assets
WHERE is_deleted = 0
  AND rating >= ?
  AND capture_date BETWEEN ? AND ?
  AND camera_model = ?
ORDER BY capture_date DESC
LIMIT ? OFFSET ?;
```

全文搜索走 FTS：

```sql
SELECT a.*
FROM asset_search s
JOIN assets a ON a.id = s.asset_id
WHERE asset_search MATCH ?
ORDER BY a.capture_date DESC
LIMIT ? OFFSET ?;
```

关键词筛选：

```sql
SELECT a.*
FROM assets a
JOIN asset_keywords ak ON ak.asset_id = a.id
JOIN keywords k ON k.id = ak.keyword_id
WHERE k.path LIKE '旅行/%';
```

### 12.8 文件变化监听

1. 每个 source root 建立 FSEvents stream。
2. 事件到达后 debounce，例如 2 秒内合并。
3. 对受影响目录做局部重扫。
4. 如果事件标记表明可能丢失事件或需要重扫子树，则做全量重扫。
5. 应用启动时仍应做轻量一致性检查，因为外部文件变化可能发生在应用未运行期间。

### 12.9 重复检测

精确重复：

1. 先按 `file_size` 分组。
2. 组内计算 quick hash：文件头尾各 1MB + size。
3. 仍重复的计算完整 SHA-256。
4. 完整哈希相同才认为精确重复。

相似重复 v2：

1. 从 256px 缩略图生成 pHash/dHash。
2. Hamming distance 小于阈值的进入候选组。
3. 更高级可使用 Vision image feature print 计算图像相似度。

### 12.10 导出实现

导出原件：

1. 用户选择目标文件夹。
2. 应用获得目标文件夹写权限。
3. 根据导出规则创建子目录。
4. 复制文件，保留原文件修改时间。
5. 同名冲突处理：跳过、覆盖、重命名。
6. 生成导出报告。

导出元数据 JSON 示例：

```json
{
  "assetId": "...",
  "filename": "IMG_0001.CR3",
  "rating": 5,
  "keywords": ["旅行", "东京"],
  "captureDate": "2026-06-14T09:00:00+09:00",
  "camera": "Canon EOS R5",
  "originalPath": "/Volumes/Photos/2026/IMG_0001.CR3"
}
```

---

## 13. 并发与后台任务

### 13.1 任务类型

| 类型 | 说明 | 优先级 |
|---|---|---|
| scan | 扫描文件夹 | 高 |
| metadata | 读取元数据 | 高 |
| thumbVisible | 可见区域缩略图 | 最高 |
| thumbBackground | 后台缩略图 | 中 |
| preview | 生成大预览 | 中 |
| hash | 计算哈希 | 低 |
| fts | 更新全文索引 | 中 |
| backup | 备份目录库 | 低 |
| cleanup | 清理缓存 | 低 |

### 13.2 调度原则

1. UI 可见请求优先。
2. CPU 密集任务限制并发数，例如 `max(2, processorCount / 2)`。
3. I/O 密集任务限制同一磁盘并发，避免机械硬盘卡顿。
4. 任务失败指数退避，最多重试 3 次。
5. 用户暂停导入时不取消已接近完成的单文件任务，但不再拉取新任务。

### 13.3 Actor 设计

```swift
actor CatalogDatabase {
    let dbQueue: DatabaseQueue

    func write<T>(_ block: @escaping (Database) throws -> T) async throws -> T {
        try await dbQueue.write(block)
    }

    func read<T>(_ block: @escaping (Database) throws -> T) async throws -> T {
        try await dbQueue.read(block)
    }
}
```

---

## 14. UI 信息架构

### 14.1 主窗口布局

```text
┌──────────────────────────────────────────────────────────────┐
│ Toolbar: Import | Search | Filter | View Mode | Export       │
├───────────────┬──────────────────────────────┬───────────────┤
│ Sidebar       │ Grid / Loupe / Compare       │ Inspector     │
│ - All Photos  │                              │ - Info        │
│ - Recent      │                              │ - EXIF        │
│ - Folders     │                              │ - Keywords    │
│ - Albums      │                              │ - Location    │
│ - Smart       │                              │ - File        │
│ - Keywords    │                              │               │
└───────────────┴──────────────────────────────┴───────────────┘
```

### 14.2 侧边栏

1. 资料库
   - 全部照片
   - 最近导入
   - 未评分
   - 被拒绝
   - 缺失文件
   - 重复文件
2. 文件夹
   - 源文件夹树
3. 相册
   - 普通相册
   - 文件夹
4. 智能相册
5. 关键词
6. 地点 v1.1+
7. 人物 v2+

### 14.3 Toolbar

- 导入/添加文件夹
- 搜索框
- 筛选开关
- 排序
- 网格大小 slider
- 视图切换：Grid / Loupe / Compare / Map
- 导出
- 任务进度入口

### 14.4 Inspector

Tabs：

1. Info：文件名、路径、大小、格式、宽高。
2. Metadata：EXIF、相机、镜头、GPS。
3. Organize：评分、旗标、颜色、关键词、标题、说明。
4. History：导入时间、修改时间、哈希、原件状态。

---

## 15. 快捷键建议

| 快捷键 | 功能 |
|---|---|
| 1-5 | 设置评分 |
| 0 | 清除评分 |
| P | 标记精选 |
| X | 标记拒绝 |
| U | 清除旗标 |
| 6-9 | 设置颜色标签 |
| G | 网格视图 |
| E / Space | 单张查看 |
| C | 比较视图 |
| Cmd+F | 搜索 |
| Cmd+I | 显示/隐藏 Inspector |
| Cmd+E | 导出 |
| Delete | 从目录库移除或移到废纸篓，弹窗确认 |
| Cmd+R | 重新扫描当前源 |

---

## 16. 错误处理与状态设计

### 16.1 资产状态

| 状态 | 含义 | UI |
|---|---|---|
| ready | 原件可访问，缓存正常 | 正常显示 |
| processing | 正在读取元数据/缩略图 | 进度或小徽标 |
| offline | 外置盘/网络盘不在线 | 离线徽标，仍显示缓存 |
| missing | 文件路径不存在 | 缺失徽标，可重新定位 |
| permissionLost | 授权失效 | 权限徽标，引导重新授权 |
| unsupported | 无法解码/读取 | 错误徽标 |
| corrupted | 文件损坏 | 错误徽标，详情显示原因 |

### 16.2 错误类别

1. 权限错误：没有文件夹访问权限。
2. 文件不存在：移动、删除、卷离线。
3. 格式不支持：系统无法生成预览或读取元数据。
4. 数据库错误：迁移失败、锁冲突、磁盘满。
5. 缓存错误：缩略图写入失败、缓存目录不可写。
6. 导出错误：目标权限、同名冲突、磁盘空间不足。

---

## 17. App 设置

### 17.1 常规

- 默认目录库位置。
- 启动时打开上次目录库。
- 最近导入天数。

### 17.2 导入

- 默认引用式/托管式。
- 支持文件类型。
- 是否跳过疑似重复。
- 托管式导入目录结构：按 `YYYY/MM/DD`、按相机、按项目。

### 17.3 缩略图与缓存

- 缩略图尺寸。
- 是否生成 2048px 预览。
- 最大缓存大小。
- 清理缓存。
- 重建缓存。

### 17.4 元数据

- 是否读取 XMP sidecar。
- 是否自动写入 XMP sidecar。
- 元数据冲突策略：目录库优先 / sidecar 优先 / 提示。

### 17.5 性能

- 后台任务并发数。
- 使用电池时降低后台任务。
- 外置盘扫描速度限制。

### 17.6 隐私

- 清除最近目录库。
- 清除日志。
- 清除安全书签。

---

## 18. 开发任务拆分

### 18.1 Sprint 0：工程基础

- 创建 macOS Swift 项目。
- 建立模块目录。
- 集成 GRDB。
- 建立 logging。
- 建立 Catalog package 创建/打开能力。
- 建立数据库 migration。
- 建立基础单元测试。

### 18.2 Sprint 1：源文件夹与扫描

- NSOpenPanel 选择文件夹。
- Security-scoped bookmark 保存/恢复。
- source_roots 表与 UI。
- 文件枚举器。
- 支持类型判断。
- assets upsert。
- 导入进度 UI。

### 18.3 Sprint 2：元数据与缩略图

- Image I/O 元数据读取。
- ThumbnailService。
- thumbnails 表。
- 缓存路径管理。
- JobScheduler 初版。
- 网格显示占位图和缩略图。

### 18.4 Sprint 3：浏览体验

- NSCollectionView 高性能网格。
- 单张查看。
- Inspector。
- 多选。
- 快捷键评分、旗标、颜色标签。

### 18.5 Sprint 4：组织与检索

- 关键词 CRUD。
- 相册 CRUD。
- 智能相册规则。
- FTS 搜索。
- 高级筛选。
- 排序和分页。

### 18.6 Sprint 5：文件变化与可靠性

- FSEvents 监听。
- 增量扫描。
- 缺失检测。
- 重新定位原件。
- 精确重复检测。
- 目录库备份。

### 18.7 Sprint 6：导出与发布准备

- 原件导出。
- 元数据导出。
- 设置页。
- 崩溃恢复测试。
- 性能测试。
- 签名、公证、安装包。

---

## 19. 里程碑验收

### 19.1 Alpha

1. 能创建目录库。
2. 能添加文件夹并扫描 1000 张图片。
3. 能显示缩略图网格。
4. 能查看单张照片。
5. 能显示基础 EXIF。

### 19.2 Beta

1. 能管理 5 万张照片。
2. 能评分、关键词、相册、筛选。
3. 支持重启恢复任务。
4. 支持文件变化监听。
5. 支持备份和恢复。

### 19.3 v1.0

1. 能稳定管理 10 万到 20 万张照片。
2. 精确重复检测可用。
3. 缺失文件重定位可用。
4. 导出可用。
5. UI 基本完整，错误提示清晰。
6. 完成签名和发布流程。

---

## 20. 测试计划

### 20.1 单元测试

- 智能相册规则解析。
- SQL query builder。
- 关键词层级路径生成。
- 文件类型识别。
- 拍摄时间优先级。
- 缓存路径生成。
- 重复检测哈希。

### 20.2 集成测试

- 临时目录创建 1 万个模拟文件。
- 扫描、入库、修改、删除、重命名。
- 目录库迁移。
- 权限失效模拟。
- 缩略图生成失败 fallback。

### 20.3 性能测试

- 1 万、10 万、50 万 assets 数据库查询。
- FTS 搜索性能。
- 网格滚动内存。
- 缩略图批量生成速度。
- 应用启动时间。

### 20.4 兼容测试

- 内置 SSD。
- 外置硬盘。
- NAS/SMB 共享。
- iCloud Drive 文件夹。
- 只读文件夹。
- 权限被撤销。

---

## 21. 风险与规避

| 风险 | 影响 | 规避 |
|---|---|---|
| RAW 格式兼容不完整 | 用户看不到预览 | Quick Look + Image I/O + 可选 LibRaw；显示明确错误。 |
| 大图库性能差 | 核心体验失败 | 数据库索引、分页、虚拟化网格、异步任务。 |
| Sandbox 权限丢失 | 无法访问原件 | 安全书签、stale 检测、重新授权 UI。 |
| 文件变化监听丢事件 | 索引不准 | FSEvents + 启动一致性检查 + 手动重扫。 |
| 缩略图缓存过大 | 占用磁盘 | 缓存大小上限、清理策略、按需重建。 |
| 误删原件 | 严重数据损失 | 默认仅移除目录库；删除原件二次确认；移入废纸篓。 |
| 数据库损坏 | 目录库不可用 | WAL、事务、备份、启动健康检查。 |

---

## 22. 发布与打包

建议路径：

1. 先做 Developer ID 分发，便于早期用户测试。
2. 稳定后考虑 Mac App Store。
3. 开启 App Sandbox。
4. 配置用户选择文件读写权限 entitlements。
5. 使用 Hardened Runtime。
6. 做 notarization。
7. 提供自动更新可选：非 App Store 分发可用 Sparkle，但需要额外安全配置。

---

## 23. 最小可行架构代码骨架

```text
PhotoCatalog/
  PhotoCatalogApp.swift
  Presentation/
    MainWindow/
    Sidebar/
    Grid/
    Inspector/
    Settings/
  Application/
    UseCases/
    JobScheduler/
    AppState.swift
  Domain/
    Models/
    Rules/
    Errors/
  Infrastructure/
    Catalog/
    Database/
    FileAccess/
    Scanner/
    Metadata/
    Thumbnail/
    Watcher/
    Export/
    Backup/
  Shared/
    Logging/
    Extensions/
    Utilities/
  Tests/
```

示例 Repository 协议：

```swift
protocol AssetRepository {
    func upsertDiscoveredFiles(_ files: [DiscoveredFile]) async throws
    func asset(id: Asset.ID) async throws -> Asset?
    func search(_ query: AssetQuery, page: Page) async throws -> [Asset]
    func updateRating(assetIDs: [Asset.ID], rating: Int) async throws
    func markMissing(assetIDs: [Asset.ID]) async throws
}
```

示例 Use Case：

```swift
struct RateAssetsUseCase {
    let repository: AssetRepository

    func execute(assetIDs: [Asset.ID], rating: Int) async throws {
        guard (0...5).contains(rating) else { throw DomainError.invalidRating }
        try await repository.updateRating(assetIDs: assetIDs, rating: rating)
    }
}
```

---

## 24. MVP 开发优先级清单

必须先做：

1. 目录库包与数据库 migration。
2. 文件夹授权。
3. 文件扫描和 assets 入库。
4. 缩略图生成。
5. 网格显示。
6. 单张查看。
7. 评分/旗标/关键词。
8. 搜索和筛选。
9. 相册和智能相册。
10. 文件变化监听。
11. 缺失检测。
12. 备份。

可以延后：

1. 人脸识别。
2. 地图。
3. Apple Photos 导入。
4. XMP 写回。
5. 相似照片 AI。
6. 插件系统。

---

## 25. 关键决策建议

1. v1.0 采用“引用式管理”为主，避免用户担心原件被移动。
2. 所有用户元数据先写目录库，后续再提供 XMP sidecar 同步。
3. 数据库使用 SQLite + GRDB，UI 使用 SwiftUI + AppKit。
4. 缩略图优先 Quick Look，失败再尝试 Image I/O。
5. 文件夹授权必须从第一天就按 App Sandbox 设计，避免后期重构。
6. 导入、元数据、缩略图、哈希必须全部任务化、可恢复。
7. 网格性能是产品成败关键，不要用一次性加载全部图片对象的方式实现。

