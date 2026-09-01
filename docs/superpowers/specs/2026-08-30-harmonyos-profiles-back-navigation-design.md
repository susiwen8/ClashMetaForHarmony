# HarmonyOS 管理配置页返回首页设计

## 问题

首页点击“管理配置”后进入 `ProfilesPage`。该页面只有标题和“添加配置”按钮，没有显式返回入口；生产 `Index` 的 `PROFILES` 路由也没有向页面传入返回回调。用户只能依赖系统返回手势或按键，页面内无法直接回首页。

## 方案

采用与 `ProxiesPage` 相同的页面内返回模式：

- `ProfilesPage` 新增 `onBack: () => void` 回调。
- 标题栏最左侧增加资源化“返回”按钮，稳定语义 ID 为 `profiles.back`。
- 点击后只调用 `onBack()`；页面不直接持有或修改全局路由。
- `Index` 的 `PROFILES` 分支传入回调，将 `route` 设置为 `HOME`。
- 页头使用带既有间距 token 的单行布局：返回按钮、标题、添加配置按钮。标题使用 `layoutWeight(1)` 占据剩余空间，并设置左对齐、单行和 ellipsis，避免 360vp 窄屏下挤压两个按钮。
- 返回按钮满足既有最小触控尺寸和颜色 token。

不新增文案资源，复用 `app.string.common_back`。不改变系统返回键、配置详情返回、导入 Sheet、配置列表或 Profile ViewModel 行为。

## 备选与取舍

- 仅依赖系统返回：无需代码，但不满足页面可见返回入口，拒绝。
- 在 `Index` 引入通用导航栈/统一 Header：范围过大，与本次单页修复无关，拒绝。
- 页面内回调：复用现有模式、改动最小、容易测试，采用。

## 测试

- Structure contract 先验证当前缺少 `profiles.back` 和 `onBack` wiring，再锁定：
  - `ProfilesPage` 声明 `onBack`；
  - `Button($r('app.string.common_back')).id('profiles.back')` 调用 `this.onBack()`；
  - `Index` 在 `ProfilesPage` wiring 中将 `onBack` 映射到 `route = 'HOME'`。
- `Phase3UiFlow` 必须扩展而不是替换现有流程：保留导入页 `pressBack()`、HTTP 警告取消后 `pressBack()` 回到 `ProfilesPage` 的全部断言；在现有流程末尾点击 `profiles.back`，再次观察到 `home.profile.manage`。
- Structure contract 同时锁定标题的 `layoutWeight(1)`、左对齐、`maxLines(1)` 和 `TextOverflow.Ellipsis`，以及返回/添加两个按钮继续使用最小触控尺寸。
- 真机安装后重复同一路径，确认按钮可见、enabled、clickable，点击后回首页。
