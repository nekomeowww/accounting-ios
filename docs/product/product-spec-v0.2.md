# AI 协同记账 / AA 分账 App
Product Spec v0.2

状态：立项基线  
阶段：MVP  
产品形态：AI-native Collaborative Ledger  
架构原则：Local First  
正式产品名：TBD

---

# 1. 产品定义

这是一个由 AI Agent 驱动的协同账本。

用户不应该“填写一笔账”。

用户只需要告诉 Agent 发生了什么：

- 拍一张 Receipt
- “这个是我自己的”
- “我们四个均分”
- “这顿我请”
- “刚才那笔是 A 付的”
- “酒只有我和 B 喝了”

Agent 负责理解上下文、识别 Receipt、生成结构化 Expense，并完成分账。

一句话定义：

**一个不需要你记账的 AI 协同账本。**

---

# 2. 产品愿景

传统产品的流程：

```text
拍 Receipt
→ OCR
→ 表单
→ 检查金额
→ 填商户
→ 选付款人
→ 选参与人
→ 选分账方式
→ 保存
```

本产品的目标：

```text
拍 Receipt
→ Agent
→ Done
```

理想体验：

```text
[Receipt]

↓

焼肉 弘
¥18,420

你支付
4 人均分

¥4,605 / 人

已记录
```

用户随后把手机放回口袋。

---

# 3. 核心产品原则

## 3.1 Agent First

Agent 是主要操作界面。

主要输入方式：

- 图片
- 文字
- 图片 + 文字
- 后续可加入语音

传统表单只是 Escape Hatch。

---

## 3.2 Inference First

Agent 可以推断的信息，不要求用户填写。

包括：

- Merchant
- Amount
- Currency
- Date
- Time
- Items
- Category
- Place
- Payer
- Participants
- Split Rule

---

## 3.3 Act First, Undo Later

普通 Expense 默认执行。

不要：

```text
检测到 ¥8,420
是否保存？

[取消] [确认]
```

应该：

```text
已记录 ¥8,420

[撤销]
```

只有关键字段存在明显歧义时才询问。

---

## 3.4 Ask Only When Necessary

每一次询问都属于交互成本。

普通消费目标：

```text
0 次表单
0 次字段录入
0～1 次追问
```

---

## 3.5 Structured State

Conversation 只是 Interface。

真正的 Source of Truth 是结构化数据：

```text
Ledger
Member
Expense
ExpenseItem
Receipt
Place
Split
Balance
Action
```

AI 不直接充当数据库。

---

## 3.6 Local First

第一版的完整账本必须可以在没有云端服务的情况下正常工作。

包括：

- 创建 Ledger
- 创建 Expense
- Receipt 识别后的数据保存
- 修改 Expense
- 分账
- Balance 计算
- Map 展示
- 历史查询
- Undo

应用启动后优先读取本地数据库。

UI 不依赖服务器返回数据才能展示。

原则：

> 本地数据是当前设备上的即时事实，云端未来承担同步，而不是承担应用运行。

---

# 4. 为什么采用 Local First

记账是一种高频、即时的行为。

用户刚消费完以后应该能够马上：

```text
拍照
→ Done
```

不能因为：

- 网络差
- 海外漫游
- 地铁
- 餐厅地下室
- API 超时
- 同步服务不可用

导致记账失败。

尤其旅行场景天然存在不稳定网络。

因此第一版从数据层开始就采用：

```text
UI
 ↓
Local Database
 ↓
Domain Layer
 ↓
Agent / AI
```

未来加入：

```text
Local Database
      ↕
Sync Engine
      ↕
Cloud
```

而不是：

```text
UI
 ↓
Cloud API
 ↓
Database
```

---

# 5. Local First ≠ 完全离线 AI

Local First 指的是：

**账本状态和产品核心能力不依赖云端数据库。**

AI 推理本身第一版仍然可以调用云端模型。

例如：

```text
Receipt
   ↓
Cloud Vision / LLM
   ↓
Structured Result
   ↓
Local Domain Validation
   ↓
Local Database
```

如果 AI 暂时失败：

Receipt 原图依然应该可以先保存在本地：

```text
Pending Receipt

AI processing failed
[Retry]
```

不能丢失输入。

---

# 6. Future Sync Ready

虽然第一版不做完整云同步，但数据模型必须从第一天支持未来同步。

所有同步实体使用稳定 UUID：

```ts
id: UUID
```

不能使用依赖本地数据库的自增 ID。

核心实体至少保存：

```ts
id
createdAt
updatedAt
deletedAt?
version
createdBy
updatedBy
```

未来可以直接进入 Sync Engine。

---

# 7. 删除策略

同步型数据不能真正立即 Hard Delete。

应采用 Tombstone：

```ts
deletedAt: Date | null
```

本地 UI 可以立即消失，但底层保留删除状态。

未来同步以后：

```text
Device A 删除 Expense
       ↓
Sync
       ↓
Device B 收到 Tombstone
       ↓
删除本地可见状态
```

---

# 8. Action Log

所有重要修改保存 Action Log。

例如：

```text
CREATE_EXPENSE
UPDATE_EXPENSE
CHANGE_PAYER
CHANGE_SPLIT
DELETE_EXPENSE
RESTORE_EXPENSE
```

Action 保存：

```ts
Action {
  id
  ledgerId

  actorId

  type

  entityId

  before?
  after?

  createdAt
}
```

它同时服务于：

- Undo
- Audit
- Agent Context
- 未来多人同步
- 冲突处理

---

# 9. Future Collaboration

第一版本地运行，但 Domain Model 从第一天支持多个 Member。

即：

```text
Ledger
├── Me
├── A
├── B
└── C
```

第一版成员可以只是本地 Profile：

```ts
Member {
  id
  displayName
  avatar?
  isCurrentUser
}
```

未来接云端以后，再增加：

```ts
userId?
accountId?
syncIdentity?
```

不需要重构 Expense。

---

# 10. 第一版协作边界

V1：

```text
一个设备
+
多个账本成员
+
本地计算多人分账
```

不是：

```text
四个人四台手机实时同步
```

多人实时协同属于后续 Cloud Sync 阶段。

因此第一版已经能用于：

> 一个旅行小组里由其中一个人负责记录整趟旅程。

之后升级为：

> 所有人都可以添加、修改和查看。

---

# 11. 核心对象：Ledger

产品顶层统一采用 Ledger。

例如：

```text
🇯🇵 日本旅行 2026

🏠 室友账本

👫 我们两个人

🍻 周末聚餐
```

Trip 是 Ledger 的一种类型。

```ts
Ledger {
  id

  name
  type

  members[]

  defaultCurrency?

  startDate?
  endDate?

  createdAt
  updatedAt
}
```

---

# 12. 核心输入

## Receipt Only

用户：

```text
[Receipt]
```

Agent 自动：

1. Receipt Understanding
2. Merchant Detection
3. Amount Detection
4. Currency Detection
5. Items Detection
6. Place Resolution
7. Payer Inference
8. Participant Inference
9. Split Inference
10. Expense Creation

结果：

```text
焼肉 弘

¥18,420

你支付
4 人均分

已记录
```

---

# 13. Natural Language Context

用户：

```text
这个是我自己的

[Receipt]
```

Agent：

```text
7-Eleven
¥1,284

个人消费

已记录
```

---

用户：

```text
这个我们四个均分

[Receipt]
```

直接创建多人 Equal Split。

---

用户：

```text
这顿我请
```

Agent 将对应 Expense 标记为不产生成员债务。

---

# 14. Conversational Editing

用户不需要进入编辑表单。

例如：

```text
刚才那笔不是我付的，是 A 付的
```

Agent：

```text
已修改

焼肉 弘
¥18,420

A 支付
4 人均分
```

---

用户：

```text
刚刚便利店那个是我自己的
```

Agent 根据上下文解析最近 Expense 并修改。

---

# 15. Receipt Understanding

尽可能提取：

```text
Merchant
Branch

Date
Time
Currency

Items[]
  Original Name
  Normalized Name
  Translation
  Quantity
  Unit Price
  Amount

Subtotal
Tax
Service Charge
Tip
Discount
Total

Payment Method
Card Brand
Card Last 4

Address
Phone
Receipt Number
```

必须保留：

- Receipt Image
- Structured Result
- Raw Extraction
- Confidence

---

# 16. Expense Model

```ts
Expense {
  id
  ledgerId

  merchant

  placeId?

  occurredAt

  currency
  subtotal?
  tax?
  serviceCharge?
  discount?
  total

  payerId

  participants[]

  split

  category?

  receiptId?

  source

  createdAt
  updatedAt
  deletedAt?

  version
}
```

---

# 17. Expense Item

```ts
ExpenseItem {
  id
  expenseId

  originalName
  normalizedName?
  translatedName?

  quantity

  unitPrice?
  total

  participants[]

  category?
}
```

Item 从第一版就应该结构化保存。

即使 V1 UI 不提供复杂 Item Split，也不要把菜品数据压成纯文本。

---

# 18. Split

V1 必须支持：

### Equal Split

默认方式。

### Exact Amount

支持人工修改。

第一版可以把：

- Percentage
- Item Level Split

作为次级能力。

但数据模型必须能够支持 Item Participant。

---

# 19. Place Resolution

Receipt AI 完成以后，继续进行 Place Resolution。

例如：

```text
Receipt:

焼肉 弘
京都市中京区...
```

解析成：

```text
焼肉 弘 木屋町店

Latitude
Longitude
Address
Place ID
Category
```

Place 作为独立实体：

```ts
Place {
  id

  externalProvider?
  externalId?

  name
  localizedName?

  latitude
  longitude

  address?
  category?
}
```

Expense 只关联：

```ts
placeId
```

---

# 20. Map 是 V1 功能

第一版就加入：

```text
[List] [Map]
```

Map 不是旅行规划地图。

它是：

**消费的空间视图。**

用户可以直接看到：

```text
📍 麺屋 猪一
   ¥4,820

📍 松本清
   ¥7,320

📍 焼肉 弘
   ¥18,420
```

---

# 21. Map V1 Scope

地图第一版只完成四件事：

### 1. Expense Pin

有 Place 的 Expense 显示在地图上。

### 2. 聚合

同一个地点存在多笔消费：

```text
7-Eleven
¥1,284
¥850
¥420

Total ¥2,554
```

可以聚合为一个 Place Pin。

### 3. Expense Preview

点击 Pin：

```text
焼肉 弘

Sep 22 · 19:34

¥18,420

你支付
4 人
```

### 4. Expense Detail

点击 Preview 进入 Expense Detail。

---

# 22. Map V1 明确不做

第一版不做：

- 路线规划
- 导航
- 实时 GPS Track
- 自动行程生成
- POI 推荐
- Nearby Search
- 景点探索
- 旅行路线重建

这些属于未来 Travel Layer。

---

# 23. 为什么 Map 应该进入 V1

Map 可以验证一个非常重要的长期假设：

> Expense 不只是金额，而是一个发生在现实地点的 Event。

如果用户第一次打开地图，就可以看到：

```text
这趟旅行的钱都花在哪里
```

它会让这个 App 与纯 AA 工具产生明显区别。

同时 Map 还能推动：

```text
Receipt → Place Resolution
```

这条链路从第一版就成熟。

未来加入 Travel App 时，不需要重新处理历史 Expense。

---

# 24. Map 与 Local First

Map 上的业务数据全部来自本地数据库。

例如：

```text
Local DB
 ↓
Expense + Place
 ↓
Map Pins
```

打开 Map 不应该向业务服务器查询 Expense。

地图底图本身可以来自系统 Map Provider。

如果没有网络：

- 已有 Expense Pin 仍然来自本地
- 已解析 Place 仍然存在
- 底图表现取决于系统地图缓存

账本数据不受影响。

---

# 25. Agent Context

Agent Context 至少包括：

```text
Current User

Current Ledger
Ledger Members

Recent Expenses
Recent Actions
Recent Messages

Known Places

Known Payment Methods

Ledger Defaults
```

例如：

```text
****1234
过去 12 次均为 Innei 使用
```

新 Receipt：

```text
VISA ****1234
```

Agent：

```text
payer = Innei
confidence = 0.98
```

直接执行。

---

# 26. Confidence

Agent 的结构化推断附带 Confidence：

```ts
{
  merchant: 0.99,
  total: 1,
  place: 0.94,
  payer: 0.96,
  participants: 0.82
}
```

UI 不必显示数字。

系统使用它决定：

```text
Execute
or
Ask
```

---

# 27. Agent Actions

LLM 不直接写数据库。

只能调用 Domain Actions：

```text
createExpense
updateExpense
deleteExpense

assignPayer
assignParticipants
updateSplit

attachReceipt

resolvePlace

createLedger
addMember

undoAction

queryBalance
```

流程：

```text
User Input
     ↓
Agent
     ↓
Structured Action
     ↓
Domain Validation
     ↓
Local Transaction
     ↓
Action Log
     ↓
UI Update
```

未来加入云同步以后：

```text
Local Transaction
     ↓
Sync Queue
     ↓
Cloud
```

Agent 层不需要重构。

---

# 28. Local Storage Architecture

推荐逻辑结构：

```text
Presentation
     ↓
Domain
     ↓
Repository
     ↓
Local Database
```

Agent 同样经过 Domain：

```text
Agent
 ↓
Domain Actions
 ↓
Repository
 ↓
Local Database
```

禁止：

```text
Agent
 ↓
直接修改 SQLite
```

这样以后云同步可以插入 Repository / Sync Layer，而不污染产品逻辑。

---

# 29. Sync Queue 预留

虽然 V1 不上传云端，但可以预留同步状态：

```ts
syncState:
  | 'local'
  | 'pending'
  | 'synced'
  | 'conflict'
```

以及：

```ts
localVersion
remoteVersion?
```

第一版全部：

```text
local
```

未来加入 Cloud 时，不需要改变 Domain Model。

---

# 30. Receipt Storage

Receipt 第一版保存在本地。

数据库只保存 metadata 和路径引用。

例如：

```ts
Receipt {
  id

  localAssetId

  width
  height

  extraction

  createdAt
}
```

需要考虑：

- App Sandbox
- Backup Policy
- Image Compression
- Thumbnail
- Original Retention

不要把大图片 Blob 直接塞入主数据库。

---

# 31. 首页

首页显示 Ledger。

例如：

```text
Japan 2026

你应收
¥12,820

A    ¥4,200
B    ¥5,620
C    ¥3,000
```

主 CTA：

```text
Ask Agent…
```

支持：

```text
Camera
Photo
Text
```

---

# 32. Ledger 主页面

推荐第一版结构：

```text
Japan 2026

[Activity] [Map]
```

Activity 是默认视图。

---

## Activity

```text
Today

焼肉 弘
¥18,420
你支付 · 4 人均分

7-Eleven
¥1,284
个人消费
```

Agent Message 可以直接嵌入 Timeline。

不需要额外做一个完全独立的 Chat App。

底部始终提供：

```text
[ + ]  Ask Agent…
```

---

## Map

显示当前 Ledger 所有具有 Place 的 Expense。

因此这个产品从第一版就存在两种观察方式：

```text
Activity
= 我们花了什么钱

Map
= 我们在哪里花了钱
```

---

# 33. Expense Detail

详情页是 Form 的主要存在位置。

用户可以查看：

```text
Merchant
Place
Date
Amount
Payer
Participants
Split
Items
Receipt
```

并手动修改。

但普通流程不主动进入这里。

---

# 34. Balance

Balance 必须完全由确定性 Ledger Engine 计算。

例如：

```text
你应收 ¥12,830

A 欠你 ¥4,420
B 欠你 ¥5,210
C 欠你 ¥3,200
```

LLM 不允许凭 Conversation 自己算账。

必须：

```text
Agent
 ↓
queryBalance()
 ↓
Ledger Engine
```

---

# 35. Undo

Agent 创建或修改 Expense 后：

```text
已记录

[Undo]
```

Undo 使用 Action Log。

未来同样支持：

```text
撤销刚才那个修改
```

---

# 36. V1 P0

必须完成：

- Local Database
- Ledger
- Local Members
- Receipt Image Input
- AI Receipt Understanding
- Merchant Extraction
- Item Extraction
- Date / Time
- Currency
- Total
- Expense Creation
- Payer
- Participants
- Equal Split
- Balance Engine
- Agent Natural Language Editing
- Undo
- Expense Detail
- Manual Correction
- Place Resolution
- Place Storage
- Expense Map
- Map Pin Preview
- Local Receipt Storage

---

# 37. V1 P1

核心体验稳定后加入：

- Exact Split
- Item Split
- Payment Method Memory
- Multi Currency
- Exchange Rate
- Duplicate Receipt Detection
- Better Place Matching
- Search
- Voice Input
- Receipt Translation
- Advanced Statistics

---

# 38. V2 / Cloud

第二阶段再加入：

```text
Account
Cloud Storage
Sync Engine
Invite Link
Multi-device
Realtime Collaboration
Conflict Resolution
Shared Receipt Assets
Push Notifications
```

核心数据流：

```text
Device A
Local DB
   ↕
 Sync
   ↕
Cloud
   ↕
 Sync
   ↕
Local DB
Device B
```

Cloud 不是单一 Source of Truth。

每个设备都有自己的 Local Replica。

---

# 39. 冲突策略预留

未来协同以后最容易冲突的是：

- Payer
- Participants
- Amount
- Split
- Deleted Expense

不能简单对整个 Expense 使用：

```text
Last Write Wins
```

更合理的是字段级 Version / Operation Merge。

但 V1 不实现 Conflict Resolver。

这里只要求数据结构不要堵死未来实现。

---

# 40. Explicit Non-Goals

第一版不做：

- 实时多人同步
- 行程规划
- 酒店搜索
- 机票搜索
- 景点推荐
- Route Planning
- GPS Tracking
- 游记
- 照片管理
- Travel Social
- 银行账户同步
- 自动转账
- 企业报销
- 资产管理

Map 是例外。

但 Map 只承担 Expense Visualization。

---

# 41. MVP 核心指标

## Receipt → Expense

目标：

**普通 Receipt < 10 秒。**

---

## Manual Interaction

平均：

```text
< 1 次 / Expense
```

---

## Zero-edit Rate

MVP：

```text
> 70%
```

长期：

```text
> 90%
```

---

## Agent Question Rate

目标：

```text
< 0.3 / Expense
```

---

## Place Resolution Rate

有明确商户信息的 Receipt：

目标：

```text
> 80%
```

可以正确关联到真实 Place。

---

## Map Coverage

有现实商户地点的 Expense 中：

尽可能高比例能够出现在 Map。

这会成为 Place Resolution 的直接质量指标。

---

# 42. MVP 核心假设

第一版只证明四件事：

### A

用户愿意：

```text
拍 Receipt
→ Agent
```

而不是手工填写。

### B

绝大部分账可以在不打开 Form 的情况下完成。

### C

账本上下文会持续减少 Agent 的追问。

### D

Place + Expense Map 能够让账本产生超越“欠多少钱”的额外价值。

---

# 43. 长期数据模型

现在积累的数据：

```text
Person
   ↕
Ledger
   ↕
Expense
 ↙      ↘
Place   Receipt
 ↓
Items
```

未来可以自然变成：

```text
Trip
 ↓
Timeline
 ↓
Event
 ├── Place
 ├── Expense
 ├── Media
 └── People
```

因此当前 App 可以独立成立。

如果未来 Travel Agent 成立，它又可以直接成为其中的 Expense Layer。

---

# 44. 产品约束

每增加一个功能，必须回答：

### 1

它是否减少用户操作？

### 2

Agent 能否替用户完成？

### 3

它是否直接改善 Receipt → Expense → Split？

### 4

它是否帮助理解“钱在哪里花了”？

如果四者都不是：

```text
Later
```

---

# 45. V1 最终体验

四个人旅行。

吃完饭。

用户拍一下 Receipt。

```text
焼肉 弘
¥18,420

你支付
4 人均分

¥4,605 / 人

已记录
```

回到 Ledger：

```text
Activity | Map
```

打开 Map：

```text
📍 焼肉 弘
   ¥18,420

📍 7-Eleven
   ¥1,284

📍 麺屋 猪一
   ¥4,820
```

所有数据已经存在本地。

没有账号、没有服务器、没有同步服务，核心产品仍然完整可用。

未来接入云端以后，只增加：

```text
Sync + Collaboration
```

而不是重新设计整个账本。

---

# 46. 第一阶段工程原则

**Local First.**

**Agent First.**

**Structured State.**

**Act First, Undo Later.**

**Map Expenses, not Trips.**

**Build the smallest complete loop before expanding the product.**

---

# 47. 增补：Export As / Save As

新增日期：2026-09-23。用户确认 V1 支持本地文件导出与另存为；本节为原 v0.2 的会话增补。

账本自动保存到本地数据库。Export As / Save As 用于生成一个时刻的独立文件副本，不改变当前账本的存储位置。

- Export As：生成 XLSX，打开系统分享面板。
- Save As：生成 XLSX，再选择文件名与保存位置。
- XLSX 从当前账本的有效数据生成，包含消费及逐项目分摊、成员余额；一张账单的多个项目保留在同一个消费 ID 下。
- 范围为当前账本；文件在本地生成，无须业务服务器。云盘目标的上传取决于对应文件服务。
- 取消和失败不影响已有账本。文件包含导出时的快照，后续修改不会自动更新已导出的文件。
- 不默认包含 API Key、私有对话、AI 原始响应、已删除记录与撤销历史。
- XLSX 用于查看和分析账目，不作为账本备份或导入恢复格式。

本项纳入 V1 范围。无需写入 Google Sheets 或持续同步；PDF、导入恢复与其他格式不在当前需求内。
格式与验收细节见 [技术 Spec 第 9 节](../technical/technical-spec-v0.1.md)。
