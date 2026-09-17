# 维护者手册：同步上游更新

这个仓库不是上游的 fork，所以"同步上游"= **移动 pin + 同步依赖元数据 + 重新验收**，不是 rebase。
硬约束只有一条：**`nix/metadata/` 必须与 flake 锁定的源码严格对应，并且必须提交进 git。**

## 0. 先看会变化的东西

| 要动的东西 | 在哪 | 什么时候动 |
|---|---|---|
| `dsh-src`（稳定版 tag） | `flake.nix` 的 input | 上游发新 tag |
| `dsh-nightly-src`（master） | `flake.nix` 的 input | 想跟 master |
| `nixpkgs` | `flake.nix` 的 input | 需要新工具链时单独动，不要混在同一次升级里 |
| `nix/metadata/<lockKey>/` | 生成物，入库 | 上游改了 `pnpm-lock.yaml` 或 `pnpm-workspace.yaml` |
| pnpm 版本 | `nix/dsh.nix` 的 `resolvedPnpm`（版本 + hash） | 需要 pnpm 新特性时手动动 |
| `@file:` 配置改写 | `nix/prepare-runtime.py` | 上游改了那两条设置的写法时 |

**注意：一个新 tag 不一定改 lock。** 实测 `dsh-v0.1.5-rc.1 → rc.2` 的 `pnpm-lock.yaml` 与
`pnpm-workspace.yaml` 完全一致，所以 `lockKey` 不变、无需重生成元数据，只是 `source.json`
里记录的版本号要跟着走。

## 1. 标准升级流程

```sh
# 1) 改 pin（flake.nix 里 dsh-src 的 tag；只跟 nightly 就跳过这步）
#    然后锁定新 revision：
nix flake update dsh-src            # 只动这一个 input
# 也可以不改文件直接切：
#   nix flake lock --override-input dsh-src github:deepseek-ai/deepseek-harness/dsh-v0.1.5-rc.2

# 2) 同步依赖元数据（幂等：已最新时什么都不做）
nix/update-metadata-for-input.sh            # 默认两个输出都检查
nix/update-metadata-for-input.sh dsh        # 或只检查某一个

# 3) 构建两个输出
nix build .#dsh .#dsh-nightly

# 4) 验收（需要临时 HOME，不需要 API key）
python3 nix/smoke-test.py ./result --node "$(nix eval --raw .#dsh.node)/bin/node"
```

第 4 步期望输出：

```
PTY: passed
{"version": "0.1.5-rc.1", "cli": "passed", "web": "passed", "assets": 4}
```

其中 `version` 必须等于新 tag 的版本。

## 2. 提交

一次升级提交里应当同时包含：

- `flake.nix`（如果改了 tag）与 `flake.lock`
- `nix/metadata/**` 的新增/变更

漏提交元数据是最容易犯也最隐蔽的错误：`nix build` 只把**已跟踪**文件复制进 store，
所以本地（脏树、impure 求值）看起来一切正常，换一台机器或 CI 上会在求值阶段直接失败，
报 `dsh: missing dependency metadata for <lockKey>`。

提交信息的建议格式：

```
Update dsh-src to v0.1.5-rc.2

lockKey unchanged (a6515566578a26c2); only the recorded version moved.
Verified: nix build .#dsh .#dsh-nightly, smoke test cli/pty/web passed.
```

## 3. 什么情况下会失败，以及怎么处理

| 症状 | 含义 | 处理 |
|---|---|---|
| `missing dependency metadata for <lockKey>` | 上游改了 lock，元数据没生成或没提交 | 跑第 1 步的脚本，然后**提交** |
| `source and dependency metadata differ` | 元数据是别的 revision 的 | 同上；不要手改 `source.json` |
| `has format N, expected M` | 元数据格式版本旧了 | 用当前 `update-metadata.py` 重新生成 |
| `ERR_PNPM_INVALID_VERSION_UNION` / `ERR_PNPM_NAME_PATTERN_IN_VERSION_UNION` | 上游在 `allowBuilds` 或 `minimumReleaseAgeExclude` 里新增了 `@file:` 形式的 workspace 条目 | 在 `prepare-runtime.py` 的具名改写里覆盖它，并在 `test-prepare-runtime.py` 加断言；不要放宽成通配改写 |
| `ERR_PNPM_OUTDATED_LOCKFILE`（提到 `apps/nix-runtime`） | 生成的运行时 manifest 与 lock importer 不一致 | 检查 `prepare-runtime.py` 里 specifier 的推导（root `overrides` 的 `link:` 必须按运行时目录重新定位） |
| `ERR_PNPM_LOCKFILE_CONFIG_MISMATCH`（提到 `injectWorkspacePackages`） | workspace 配置与 lockfile `settings` 不一致 | 两者由 `prepare-runtime.py` 同时写入，检查是否被改坏 |
| `ERR_PNPM_DEPLOY_NONINJECTED_WORKSPACE` | 同上的部署侧表现 | 同上 |
| 依赖安装末尾 `uv__io_poll, kqueue.c` + `Abort trap: 6` | pnpm 跑在 Node 24 上崩了 | 确认 `pnpmNode` 仍是 `nodejs_22`；这是沙箱内必现、与安装内容无关的问题 |
| 运行时校验报 `cannot resolve required dependency X` | 部署闭包真的缺包 | 回到 `prepare-runtime.py` 的 manifest 生成逻辑修，**不要**加"缺哪个就复制哪个"的兜底 |
| `missing dependency metadata`（upstream 新 lock 里出现 git 依赖） | 有依赖没有 integrity | `update-metadata.py` 会直接报错；需要为它写显式、可审查的 fetcher，不要用占位哈希 |

## 4. 单独升级 nixpkgs

只在需要新工具链时做，且**单独一次提交**，便于出问题时回滚：

```sh
nix flake update nixpkgs
nix build .#dsh .#dsh-nightly
python3 nix/smoke-test.py ./result --node "$(nix eval --raw .#dsh.node)/bin/node"
```

会连带变化、需要留意的：

- `runtimeNode` = `nodejs_24`，安装出来的 `dsh` 用的 Node 版本会跟着 nixpkgs 变。
- `pnpmNode` = `nodejs_22`。如果某天 nixpkgs 不再提供 `nodejs_22`，构建会在求值阶段失败——
  那时要么改用当时可用的旧 Node，要么确认 Node 24 的 libuv 问题已经修好再撤掉这个拆分。
- nixpkgs 变了以后整个闭包（Node、pnpm、Python）都会重建，验收必须重跑，不能只看构建通过。

## 5. pnpm 版本

`nix/dsh.nix` 里 `pnpm_11.override { version; hash; }` 钉住 pnpm，`hash` 是 npm 上那个 tarball 的
SRI。上游 `package.json` 的 `packageManager` 字段被 `prepare-runtime.py` 删掉了，所以 pnpm 版本
完全由这里决定。升级 pnpm 时：

```sh
# 用占位 hash 让 Nix 报出真实值
nix build --impure --no-link --print-out-paths --expr '
  let f = builtins.getFlake (toString ./.);
  in f.inputs.nixpkgs.legacyPackages.aarch64-darwin.pnpm_11.override {
       version = "11.26.0"; hash = "sha256-AAAA..."; }'
```

硬性下限是 **pnpm >= 11.22.0**（`nix/dsh.nix` 有断言），因为 workspace 部署需要它。
升级 pnpm 后必须重跑验收：`prepare-runtime.py` 的两处改写是针对 11.25 的解析行为写的，
换版本可能改变哪些配置会被拒绝。

## 6. 验收的边界

- `nix build` 内的检查只有 CLI `--version` / `--help` 和运行时闭包校验。
- PTY 与 Web 只能在构建沙箱之外验证（需要真实 PTY 与回环端口），所以**升级后必须手动跑
  `nix/smoke-test.py`**，不能只依赖 `nix build` 成功。
- 新增平台支持时，`meta.platforms`、`nix/import-pnpm-lock.nix` 的平台过滤、以及
  `nix/dsh.nix` 里 spawn-helper 那行（目前是 darwin 专用）都要一起改，并各自跑一遍验收。

## 7. 不要做的事

- 不要手改 `nix/metadata/**` 里的哈希或版本；永远用 `update-metadata.py` 重新生成。
- 不要把元数据留在未提交状态。
- 不要在 `prepare-runtime.py` 里写"为了让安装过去就删配置"的通配逻辑；只做具名改写 + 断言。
- 不要为了"跑通"往部署产物里复制缺失依赖；缺依赖就修 manifest。
- 不要把 `nixpkgs`、源码 tag、pnpm 三件事塞进同一个提交——出问题时无法二分。
