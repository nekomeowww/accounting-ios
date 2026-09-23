# 消费地图与地点解析 Spec

日期：2026-09-23。状态：已讨论定稿，待实现。
上游：[产品 Spec v0.2](../../product/product-spec-v0.2.md) 第 19–24、32 节；[Agent 记账卡片 Spec](2026-09-23-agent-expense-proposal-design.md)；[pi Agent Runtime Spec](2026-09-23-pi-agent-runtime-design.md)（占用迁移 v5，本 Spec 用 v6）。
依据：`~/trips` 13 个记账 session 的地点推断复盘（见第 2 节）。

## 1. 范围

地图是「消费的空间视图」：这趟旅行的钱花在哪里。V1 只做：

1. 有地点的 Expense 显示为 Pin。
2. 同一地点多笔消费聚合为一个 Pin。
3. 点 Pin 出预览卡片。
4. 预览进入 Expense 详情。

外加让 Pin 有数据的**地点解析**：Agent 提供线索 → MapKit 搜索 → 用户在记账卡片上确认。

已知限制：在中国大陆网络下 Apple 地图搜索由高德提供，搜不到日本等海外店铺（返回 placemarkNotFound）；此时地点标「待确认」并保留线索，回到当地或之后在详情页重搜。V1 不接第三方地点服务。

不做：路线、导航、GPS 轨迹、行程生成、POI 推荐、附近搜索、按日期筛选、定位按钮、设备定位权限、Agent 联网搜索。

## 2. 设计依据：session 复盘

trips 记账 session 中 AI 推出的分店和地址准确，原因是：

- **分店名本身就在输入里**：小票抬头或口述「…京都四条河原町店」决定了绝大多数情况。
- **上下文消歧**：行程（哪天在哪个城市）、住宿、同一天前后几笔消费的位置。例：9/18 在热海站取车 → 五味八珍锁定 ラスカ熱海店。
- **搜索只做确认**：店名 + 电话号码查询补全街区或地址。
- 从未产出坐标，只到店名、分店和街区这一层。
- 唯一的漏：麺屋 猪一 有本店和離れ，AI 静默选了一家，没问用户。

结论：模型负责**线索**，App 负责**坐标**，多候选必须让用户选。

## 3. 入口与页面

### 3.1 入口

账本页导航栏中间是分段控件 `[Activity | Map]`，默认 Activity。切换在同一个页面内完成：返回键、`⋯` 账本设置和底部 Ask Agent 保持不变。账本名移到返回栈，在返回长按菜单里可见，也可作为导航栏 subtitle。

### 3.2 Map 页

- `MKMapView` 铺满全屏，导航栏半透明。首次显示时用 `showAnnotations` 让视野容纳全部 Pin（带边距）。只有一个 Pin 时用街区级缩放。
- **Pin**：`MKMarkerAnnotationView`。
  - 图标按分类：餐饮 `fork.knife`、交通 `tram.fill`、住宿 `bed.double.fill`、门票 `ticket.fill`、购物 `bag.fill`、便利店 `cart.fill`、其他 `mappin`。
  - 颜色按分类。
  - 标题是金额（结算币种，没有汇率时用原币）。同一地点有多笔时，标题是合计，`glyphText` 显示笔数。
- **聚合**：同一 `placeId` 的消费合成一个 annotation。缩小时用 MapKit 的 `clusteringIdentifier` 合并挨得近的 Pin，cluster 标题显示合计金额。
- **预览卡片**：点 Pin 后从底部出现一张卡片，这时 Ask Agent 按钮隐藏。
  - 单笔：商户、时间、金额（带折算）、「你支付 / neko 支付」、几人分。点卡片 push Expense 详情。
  - 多笔：地点名，下面列出每笔（时间 + 金额），最后一行合计。点某一行进详情。
  - 点地图空白处或下拉卡片关闭。
- **空状态**：没有任何带地点的消费时，地图上叠一张说明：「还没有带地点的消费。记账时说出店名或分店，Agent 会帮你找到位置。」
- **离线**：Pin 全部来自本地数据库。底图显示什么取决于系统缓存，不影响账本数据。

## 4. 数据模型（迁移 v6）

```
place   id PK, ledgerId → ledger (cascade),
        name, branch?, address?, phone?, category?,
        latitude, longitude,
        provider ('apple'), providerId?        MKMapItem.identifier.rawValue
        createdAt, updatedAt
        UNIQUE(ledgerId, provider, providerId)
expense + placeId → place (set null)
        + placeQuery TEXT?                      未解析时保存的线索 JSON，用于稍后重试
```

- Place 属于账本，不跨账本共享，将来归档导出时随账本一起走。
- 同一 `providerId` 复用同一个 place 行，保证聚合时指向同一个 Pin。
- `expense` 表上已有的 `latitude/longitude/locationSource` 保留不用：它们表示的是设备位置，和店铺地点语义不同，V1 不写。

## 5. 地点解析

### 5.1 Agent 线索

`propose_expense` 增加一个可选字段 `place`：

| 字段 | 说明 |
|---|---|
| name | 店名，不含分店 |
| branch | 分店名，如「京都四条河原町店」「ラスカ熱海店」 |
| address | 小票或原话中的地址，含 〒 |
| phone | 电话 |
| area | 城市或街区，如「京都 下京区」，来自行程或当天上下文推断 |

System prompt 增加两条：
- 分店、地址、电话只能从用户原话或小票里抠，不要编造。
- `area` 可以根据住宿和当天其他消费推断，但要写在 `area` 里，不要冒充分店名。

### 5.2 Agent 上下文

在原有内容之外增加：

- 最近消费附上已确认地点的「店名 分店 · 区域」。
- 「住宿」分类消费单独列出，含地点和日期区间。这是判断「那天在哪个城市」的主要依据。

### 5.3 MapKit 搜索

卡片出现时发起 `MKLocalSearch`，不阻塞卡片显示，结果只放在内存里：

1. 查询词：有 `address` 用地址；否则用 `name branch area`。
2. 搜索范围偏好（`request.region`），按优先级：
   1. 同一天其他消费的地点
   2. 本账本的住宿地点
   3. 本账本的全部地点
   4. 不设范围
3. 候选打分：
   - 电话号码规范化后完全一致，直接选中。
   - 否则按名称包含分店名、到范围中心的距离排序，保留前 5 个。
4. 结果：
   - 1 个候选，或电话命中：卡片显示「📍 店名 · 地址」。
   - 多个候选：卡片显示「📍 店名 · N 个候选」，点开选择。
   - 0 个候选或离线：显示「📍 地点待确认」。

### 5.4 确认与写入

- 用户点「记账」时，把当前选中的候选写入 place（按 `providerId` 复用已有行）并设置 `expense.placeId`，与建账在**同一事务**内。
- 没有选中地点：`placeId` 留空，线索原文存入 `placeQuery`。
- 卡片上可以选「不关联地点」。
- 卡片上的地点选择不写入 message 行，状态只在内存里。已记账的卡片显示的是 `expense.placeId` 对应的地点。

### 5.5 详情页

- Expense 详情增加「地点」区块。有地点时显示地图快照（`MKMapSnapshotter`）、名称和地址；点快照进入地图页并定位到这个 Pin。
- 没有地点、但有 `placeQuery` 时，显示「重新搜索」，复用 5.3 的逻辑；没有 `placeQuery` 时显示「添加地点」，打开搜索框。
- 可以把地点改掉或移除。

## 6. 示例数据

DebugSeed 为 trips 的消费补上真实地点，全部来自 session 中已确认的店名和分店：墨田区 Airbnb、TOYOTA 热海站店、ラスカ熱海店、伊豆高原猫咪博物馆、麺屋 猪一、高島屋京都、マツモトキヨシ 京都四条河原町店、京都まるん 祇園店、おにまる 京都四条河原町店、Sanrio Gallery 京都店、teamLab Planets 等。坐标写死在 seed 里，不在运行时搜索。

Debug 页新增一行 `open-map`，并新增一个组件页「地图预览卡片」，含单笔、多笔两种状态。

## 7. 模块

| 位置 | 内容 |
|---|---|
| `LedgerDomain` | `Place`、`PlaceHint`（`ExpenseProposal.place`）、电话规范化、候选打分（纯函数） |
| `LedgerPersistence` | 迁移 v6，`fetchMapPins(ledgerId)`（按 place 聚合），`acceptProposal(..., place:)` |
| App `Map/` | `LedgerMapView`（MKMapView 封装）、预览卡片、`PlaceSearch`（MKLocalSearch + 打分） |
| App | 账本页分段切换；卡片地点行；详情页地点区块 |

## 8. 验证

- 单元测试：
  - 电话规范化（`075-229-6955` 和 `+81 75 229 6955` 视为一致）
  - 候选打分（电话命中优先，其次分店名和距离）
  - `fetchMapPins` 按 place 聚合并算出合计
  - 接受卡片时 place 复用，且与建账在同一事务
  - 未解析时写入 `placeQuery`
- 模拟器（seed + 本地模拟 Agent）：
  - 切到 Map，看到京都、热海、东京的 Pin。
  - 四条河原町一带出现 cluster；点开多笔 Pin 能看到列表和合计。
  - 预览卡片进详情；详情页有地点快照。
  - 模拟 Agent 带分店名记账：卡片出现候选，选择后记账，新 Pin 出现在地图上。
- 真实模型：口述「五味八珍热海店 3135 日元 白水付的 两人分」，卡片候选中应包含 ラスカ熱海店。
