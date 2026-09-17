# dsh.nix 重构 Spec（第 1 轮）

目标：在 `aarch64-darwin` 上，从干净环境构建固定版本 `0.1.5-rc.1`，CLI / Web / PTY 均可用。
本轮只做这一件事；nightly、其他平台、二进制缓存、桌面端不在范围内。

---

## 1. 当前实际状态（已核实，非推测）

### 1.1 已有资产

| 资产 | 状态 |
|---|---|
| `nix/import-pnpm-lock.nix` | 逐包 `fetchurl`（用 lock 的 integrity）→ 本地 tarball 地图；`fetchPnpmDeps` 只用它预热 store |
| `nix/prepare-runtime.py` | 改写 lock 里 tarball 为本地文件、生成 `apps/nix-runtime` manifest、加 lock importer、去掉源码侧 postinstall |
| `nix/verify-runtime.mjs` | 只校验（解析依赖、检查链接不逃逸、检查 `lib/bin.js` 与前端 `dist/index.html`），缺包即失败，不复制补齐 |
| `nix/smoke-test.py` | 沙箱外运行：CLI version/help、真实 PTY 跑命令、Web 起服务并抓首页 + 页面实际引用的 `/assets/*` |
| `nix/metadata/<lockKey>/` | 每个源码 revision 一份 `lock.json`/`workspace.json`/`source.json`（含 lock/workspace 的 SHA-256 与版本） |
| `nix/update-metadata.py` + `.#update-metadata` | 由源码目录生成上述元数据，缺 integrity 直接报错 |

代码里已无对已删除文件（`hashes.json`、`pnpm.nix`、`pnpm-deps.nix`、`deploy-carrier.mjs`、`update-hashes.sh`、`prepare-runtime.mjs`）的引用。

### 1.2 现在为什么构建不过

**阻塞 1：`nix build .#dsh` 在求值阶段就失败，与依赖无关。**

```
error: dsh: missing dependency metadata for a6515566578a26c2; run update-metadata with the source path
```

原因已定位：`nix/metadata/` 从来没进过 git。`nix build .`（非 impure）把 flake 源树复制进 store 时只带**已跟踪**文件，因此

```
/nix/store/9xkyi9mqd6kxkbs26wabavp05y0rsrjx-source/nix/     # 只有 dsh.nix、home-manager.nix
```

而 impure 求值下同一个路径检查是通过的（`pathExists` 为 true），`dsh.nix` 的 `assert` 本身没问题。
也就是说：**元数据必须提交进 git，否则任何干净构建都不可能成功。**

**阻塞 2：固定版本的元数据此前缺失（已修复）。**

`ca131858949bd12b` 的 `source.json` 写的是 `version: 0.1.6-alpha.1`、`workspaceHash: 36bbdcf3…`，与 flake 锁定的 `dsh-src`（`183f08e9`，version `0.1.5-rc.1`，`workspaceHash: 6567f864…`）不是同一棵树——它是 **nightly 源**的元数据（已核实一致，见决定 B）。
固定版本的元数据 `a6515566578a26c2` 已用锁定源重新生成，内容可复现。

**阻塞 3（真正的技术难点）：pnpm 版本与上游 workspace 配置不兼容。**

上一轮 `.build.log` 里 `dsh-pnpm-deps` 的失败点：

```
ERR_PNPM_INVALID_VERSION_UNION  Invalid versions union.
Found: "@deepseek-ai/dsh-subprocess-local@file:packages/subprocess/subprocess-local". Use exact versions only.
```

已定位到来源：上游 `pnpm-workspace.yaml` 的 `minimumReleaseAgeExclude` 里有一条 workspace 链接条目的记录

```yaml
minimumReleaseAgeExclude:
  …
  - '@deepseek-ai/dsh-subprocess-local@file:packages/subprocess/subprocess-local'
```

pnpm 11.25 把该设置按 `包名@精确版本||精确版本` 解析（`parseVersionPolicyRule` → `semver.valid`），`file:` 不是合法 semver，于是硬失败。上游 `package.json` 写的是 `packageManager: pnpm@11.7.0`，即这条配置是为 11.7.0 写的。**当前 `nix/dsh.nix` 把 pnpm 覆写成 11.25.0，与上游锁定的包管理器不一致。**

补充事实（用于决策）：

- 上游 `pnpm-lock.yaml` 是 `lockfileVersion: '9.0'`，`settings` 只有 `autoInstallPeers`/`excludeLinksFromLockfile`，没有额外版本要求；`183f08e9`（tag）与 nightly 的 lock/workspace 内容一致。
- lock 里共 1543 个 `packages`、290 个 importer，全部为 registry tarball（含 integrity），无 git 依赖；逐包下载路线成立。
- 已删除的 `pnpm-hashes.json`/`hashes.json` 说明上一轮在这条路上试过两种取哈希方式，最后改成"每次先失败一次再登记整 store 哈希"。

---

## 2. 已确认的决定

### 决定 A：pnpm 版本 —— A2（保持 11.25.0，由 `prepare-runtime.py` 精确改写那条记录）

- 保留 `pnpm 11.25.0`（与现有 `pnpm_11.override` 一致，hash 已固定）。
- `prepare-runtime.py` 必须**精确、最小**地处理不兼容记录，且每条改写都要有回归测试：
  1. `minimumReleaseAgeExclude`：删掉指向 workspace 链接的 `@file:` 条目（该设置只对 registry 包的发布年龄有意义，对 workspace 链接无效）。
  2. `allowBuilds`：把 `@file:` 键归一到裸包名，保留原有 true/false 语义；**不做通配改写**。
- 改写只发生在 Nix 构建目录内的源码副本，不影响上游仓库；改写项、原因与 pnpm 版本一起写进 README。

风险登记：今后上游新增同类 `file:` 条目时要继续跟进，构建应以明确的 pnpm 报错暴露（而不是静默去掉配置）。若这条维护成本变高，第 4 步可再评估切回上游钉住的 11.7.0。

### 决定 B：`dsh-nightly` —— B1（本轮也生成并提交 nightly 元数据）

- 核实结果：现有 `nix/metadata/ca131858949bd12b/` **就是** nightly 源的元数据（`lockHash`/`workspaceHash` 与 `dsh-nightly-src` 完全一致，version `0.1.6-alpha.1`），只是目录里没有 README 说明、容易误解为"放错位置"。
- 处理：保留并纳入提交；nightly 与固定版本各自的 `lockKey` 不同（`ca131858949bd12b` vs `a6515566578a26c2`），互不覆盖。
- nightly 本轮只要求可构建/可求值，不做运行验收。

### 决定 C：元数据提交方式 —— C1（保持现有 JSON 格式直接提交）

- `nix/metadata/**` 必须提交进 git（原因见 §1.2 阻塞 1）。两个 revision 合计约 2.4 MB。
- 体积/裁剪优化留待后续（不影响本轮验收）。

---

## 3. 本轮执行计划

### 步骤 1：修好"干净构建"的入口（阻塞 1、2）

1. `nix/metadata/` 提交进 git：`a6515566578a26c2`（固定版本）+ `ca131858949bd12b`（nightly，按决定 B1 保留）。
2. 明确生成方式并写进 README：元数据从 **flake 锁定的源** 生成，避免再从任意工作树生成导致版本错配：
   ```sh
   nix build --no-link --print-out-paths --impure --expr \
     '(builtins.getFlake (toString ./.)).inputs.dsh-src'          # 或 .inputs.dsh-nightly-src
   nix run .#update-metadata -- <上面输出的路径>
   ```
3. 给 `update-metadata.py` 加一条一致性检查：生成出的 `source.json.version` 与源码 `package.json` 的版本不符时直接报错退出。

**验收**：在**干净 git 树**上 `nix build .#dsh --dry-run` 通过求值（不再出现 missing metadata）。

### 步骤 2：修好依赖获取与安装（阻塞 3 + 完整 store）

1. 按决定 A2：固定 `pnpm 11.25.0`；`prepare-runtime.py` 精确改写 `minimumReleaseAgeExclude` / `allowBuilds` 中的 `@file:` 记录，并补回归测试（现成的 `test-prepare-runtime.py` 已用 unittest 覆盖 manifest 生成逻辑，扩展它即可）。
2. 让取到的 store 覆盖**构建与部署所需的最大闭包**（这是"部署阶段依赖缺失"的根治点，而不是事后补包）：
   - build 需要 devDependencies（tsc 等构建链）；
   - deploy 需要 production 闭包；
   - 由 `fetchPnpmDeps` 用固定的 flags 抓到本地离线 store，全程 `--offline`。
3. 逐包下载器保持现有约束：无 integrity（git/tarball 直链）就显式报错，不落占位哈希。
4. `prepare-runtime.py` 里 `apps/nix-runtime` 的 manifest 生成逻辑保留；**"缺哪个包就补哪个"的通用逻辑不引入**（现有代码里也没有）。

**验收**：`nix build .#dsh` 在普通构建阶段无网络，产出 `result/bin/dsh`。

### 步骤 3：运行验收（沙箱外，不需要 API key）

| 检查 | 通过标准 | 执行 |
|---|---|---|
| CLI | `dsh --version` 输出 `0.1.5-rc.1`；`dsh --help` 退出码 0 | `nix/dsh.nix` 的 `installCheckPhase` |
| PTY | 真实 `node-pty` spawn `/bin/sh -c 'printf DSH_PTY_OK'` 并拿到输出 | `nix/smoke-test.py` |
| Web | 临时 `HOME`/`DSH_HOME` 下 `dsh web --no-open` 启动，首页 200，且页面实际引用的 `/assets/*` 与 `/manifest.webmanifest` 全部 200 | `nix/smoke-test.py` |
| 运行时完整性 | 全部 manifest 的必需依赖可解析；无指向构建目录的链接；不依赖 `.scratch`/旧 `result` | `nix/verify-runtime.mjs` + 手工确认 |
| 前端资源 | 部署产物内含 `dsh-web-frontend/dist/index.html` 与真实构建产物（非占位） | 同上 |

**验收**：一条命令跑完并打印 `{version, cli, web, assets}` 的 JSON。

### 步骤 4：收尾与文档

1. 删除仅服务于旧方案的遗留：多余元数据目录、README 里过时的描述。
2. README 只写本轮**实际通过**的版本、平台、命令与已知限制。
3. 保留对外接口：`dsh`、`dsh-nightly`、`overlays.default`、`homeManagerModules.default`、`lib.<system>.mkDsh` / `mkDshFromPath`。
   `mkDshFromPath`/任意 revision 覆盖时，若源码与元数据不匹配，明确报错（现有 `source.json` 校验已能做到），不承诺"换个 revision 就能用"。

### 不在本轮范围

- nightly 的运行验收（仅要求按决定 B 可构建）
- Linux / x86_64-darwin / 桌面端 / 二进制缓存（Cachix）
- 元数据体积优化（决定 C2，可后续做）
- 向上游提 issue/PR（等本轮构建通过、证据完整后再单独做）

---

## 4. 风险与未决点

1. **`pnpm deploy` 与新增 lock importer 的兼容性**：`prepare-runtime.py` 往 lock 里插 `apps/nix-runtime` importer。pnpm 的 frozen-lockfile 校验是否接受它，需要用一次 5 分钟实验确认；若不接受，退路是"部署时用 `--prod` 单独安装到临时目录再组装"，仍然不需要复制补齐逻辑。
2. **改写上游 workspace 配置的边界（决定 A2 的代价）**：改写只允许两类——删除指向 workspace 链接的 `minimumReleaseAgeExclude` 条目、把 `allowBuilds` 的 `@file:` 键归一到裸包名。任何"为了让它装上"的删除都必须先有 `test-prepare-runtime.py` 的回归断言，并且构建日志里要能看出改写了什么；不允许静默吞掉配置错误。
3. **node-pty helper 的可执行位**：上游用 `@deepseek-ai/dsh-subprocess-local` 的 postinstall 修复，而部署时 `--ignore-scripts`。现有做法是在部署后单独调用上游脚本；这一处要在步骤 3 的 PTY 检查里被真实验证覆盖。
