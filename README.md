# dsh.nix

把 [deepseek-harness](https://github.com/deepseek-ai/deepseek-harness)（`dsh`）从源码构建成 Nix 包，
用来声明式安装、并且可以切换版本（release tag / nightly / 任意 commit / 本地 checkout）。

```sh
nix run github:acehinnnqru/dsh.nix          # 直接跑
nix profile install github:acehinnnqru/dsh.nix
```

已在 `aarch64-darwin` 上验证：`nix build .#dsh` 成功，`dsh --version` 输出 `0.1.5-rc.1`，
`dsh web` 能从只读的 store 路径启动并正常提供前端资源（`/manifest.webmanifest` 与
`assets/*.js` 均返回 200）。产物约 210 MB，构建期不需要网络。

## 它是怎么构建的

构建期**完全不联网**（依赖全部来自固定的 FOD），流程就是仓库自己的构建流程：

1. `pnpm install --offline --frozen-lockfile` —— 依赖来自 `fetchPnpmDeps` 抓下的 pnpm store。
   构建期用 `--config.trustLockfile=true` 跳过需要 registry 的供应链校验（那次校验在抓取阶段
   已经联网跑过），并且使用仓库 `package.json` 里 `packageManager` 声明的 pnpm 版本
   （见 `nix/pnpm.nix`：nixpkgs 的 pnpm 更新，会拒绝这个 workspace 的 `allowBuilds` 写法）。
2. `pnpm run build` —— 原生 `flock` addon（用 Node headers 编译 C）、Host/Client 两个 TypeScript
   aggregate、tsdown 打包、Vite 构建 Web 前端。
3. 把构建好的 workspace 装进 `$out/lib/dsh`（源码 + 构建产物 + 上面那份 `node_modules`），
   再由 `nix/deploy-carrier.mjs` 校验/修补：没有链接指向树外、依赖与 peer 闭包完整、
   node-pty 的 `spawn-helper` 有可执行位、悬空的 optional 链接被清掉。
4. `makeWrapper` 出 `$out/bin/dsh`，实际执行
   `node --expose-internals $out/lib/dsh/python/sdk-runtime/runtime-bootstrap.mjs`。

`--expose-internals` 是必须的：Web profile 默认 `patchReload: live`，会加载
`@deepseek-ai/cordis-plugin-hmr`，而它需要 Node 的内部 module loader（仓库自己的开发脚本
`pnpm dsh` 也带这个 flag）。

### 为什么 deploy 需要 ≥ 11.22.0 的 pnpm

仓库 `packageManager` 钉的是 pnpm 11.7.0，而在那个版本上 `pnpm deploy` 只能走 legacy 实现：
legacy 路径在 `node-linker=hoisted` 时会关掉 lockfile（pnpm 源码里就是
`useLockfile: opts.nodeLinker !== "hoisted"`），于是构建期必须联网重新解析 —— 纯 Nix 构建跑不通。
从 **11.22.0** 起 `pnpm deploy` 会注入 workspace 依赖（[pnpm/pnpm#13754](https://github.com/pnpm/pnpm/pull/13754)），
注入状态记录在 lockfile 的 `settings.injectWorkspacePackages` 里，这条路完全由 lockfile 驱动、
不需要 registry。社区打包 [moraxyc/deepseek-harness.nix](https://github.com/moraxyc/deepseek-harness.nix)
用的正是这条（它的 overlay 里就钉着 `pnpmWorkspaceDeployMinVersion = "11.22.0"`），本仓库的 FOD、
install 与 deploy 因此统一到 nixpkgs 的 `pnpm_11`。

同理，构建必须在**开启注入之前**完成：注入会把 workspace 包按 `files` 字段拷成发布形态
（只有 `lib/`），而构建期需要解析 `@scope/pkg/src/...` 这类子路径。

## 用法

### nix-darwin / NixOS（overlay）

```nix
{
  inputs.dsh.url = "github:acehinnnqru/dsh.nix";

  nixpkgs.overlays = [ inputs.dsh.overlays.default ];

  environment.systemPackages = [
    pkgs.dsh           # release（跟 dsh-src 输入，默认 dsh-v0.1.5-rc.1）
    # pkgs.dsh-nightly # 跟 main 分支
  ];
}
```

用 overlay 的好处是它使用**你自己的 nixpkgs**，不会多出一份 Node/pnpm 版本。
也可以不用 overlay，直接引用 flake 的包：`inputs.dsh.packages.${pkgs.system}.dsh`。

### home-manager

```nix
{
  imports = [ inputs.dsh.homeManagerModules.default ];

  programs.dsh = {
    enable = true;
    home = "~/.dsh";        # 可选：设置 DSH_HOME，默认就是 ~/.dsh
    pluginManager = true;   # 可选：把 pnpm 放进 dsh 的 PATH，供 `dsh plugin` 管理 profile
    # package = inputs.dsh.packages.${pkgs.system}.dsh-nightly;
  };
}
```

### 开发 shell

```sh
nix develop          # 与构建同版本的 node + pnpm + git + jq + ripgrep
nix flake check      # 把 dsh 作为 check 构建
```

## 切换版本

**1. 换 release tag**（或任何 ref）：

```sh
nix flake lock --override-input dsh-src github:deepseek-ai/deepseek-harness/dsh-v0.1.5-rc.2
nix run .#update-hashes -- dsh   # 新 revision 需要登记依赖 hash（见下节）
nix build .#dsh
```

或者改 `flake.nix` 里的 `dsh-src.url`，再 `nix flake update dsh-src`。

**2. nightly**：`packages.<system>.dsh-nightly` 固定跟踪 `master`，
用 `nix flake update dsh-nightly-src` 前进到最新。

**3. 任意 revision / 本地 checkout**：flake 暴露了 `lib.<system>.mkDsh`：

```nix
let dshLib = inputs.dsh.lib.${pkgs.system};
in {
  environment.systemPackages = [
    (dshLib.mkDsh {
      src = builtins.fetchTree {
        type = "github";
        owner = "deepseek-ai";
        repo = "deepseek-harness";
        rev = "<40 位 commit>";
        narHash = "sha256-...";
      };
    })
    # 本地目录（未提交改动也会生效，自动排除 node_modules/.git）
    # (dshLib.mkDshFromPath /Users/rqc/r/github.com/deepseek-ai/deepseek-harness)
  ];
}
```

已经用了 overlay 的话等价写法是 `pkgs.dsh.override { src = ...; }`。

## 依赖 hash 是怎么维护的

`nix/hashes.json` 按 **lockfile 自身的 sha256 前 16 位**索引，所以同一份 lockfile 只登记一次，
多个 revision 可以共存：

```json
{
  "a6515566578a26c2": {
    "version": "0.1.5-rc.1",
    "hashes": { "aarch64-darwin": "sha256-P7Dtm6qInTTXoDHcx4V2CfTlVK/0Rjl0omm3W3nQXqE=" }
  }
}
```

没有登记的 revision 会用占位 hash 构建，Nix 因此报错并打印它算出来的真实 hash；
`nix run .#update-hashes` 会自动跑一遍、读回 hash、写进注册表：

```sh
nix run .#update-hashes                    # dsh + dsh-nightly + pnpm，当前系统
nix run .#update-hashes -- dsh-nightly     # 只更新一个
DSH_NIX_SYSTEM=x86_64-linux nix run .#update-hashes -- dsh   # 需要该平台的 builder
```

hash 是**按平台**的（pnpm 只为当前平台拉 optional 依赖），所以每个平台第一次都要跑一次。
目前只登记了 `aarch64-darwin`；Linux 需要在该平台（或配置了 linux builder 时）跑一次上面的命令。

> 注意：如果改动的是**抓取方式**（`fetchPnpmDeps` 的参数）而不是源码，已登记的同名 hash 会让
> Nix 直接复用旧产物。这种情况要先删掉 `nix/hashes.json` 里对应平台的条目，再跑 `update-hashes`。

## 已知限制

- **产物约 210 MB**；构建期需要约 1.5 GB store + 290 MB 元数据缓存（只存在于构建期，不进运行闭包）。
- 首次构建要抓约 1.8 GB 的依赖与元数据并跑完整构建，比较慢；换 revision 时依赖没变就直接复用 store。
- 运行时用 nixpkgs 的 Node 24（wrapper 里钉死，不依赖系统 Node）。
- `dsh plugin ...` 需要 pnpm 在 PATH 上（HM 的 `pluginManager = true`，或
  `pkgs.dsh.override { extraRuntimePath = [ pkgs.pnpm ]; }`）。
- 每次换 revision 都要登记一次依赖 hash。

## 为什么用 Nix 而不是 brew / npx

| | Nix（本仓库） | `npx @deepseek-ai/dsh web` | Homebrew formula |
|---|---|---|---|
| 声明式、可回滚 | ✅ `flake.lock` 钉死 | ❌ | ⚠️ 版本跟着 formula 走 |
| 钉任意 commit / 本地源码 | ✅ `mkDsh` / `mkDshFromPath` | ❌ 只能装已发布版本 | ❌ |
| 跨机器一致（macOS + Linux） | ✅ 同一份定义 | ⚠️ 各自 `npm install` | ⚠️ macOS/Linux 两套 formula |
| 与 nix-darwin / HM 集成 | ✅ | ❌ | ⚠️ 只能 `brew bundle` |
| 上手成本 | 中（首次构建慢、体积大） | 最低 | 低 |
| 是否需要维护者发版 | ❌ 自己从源码构建 | 需要 npm 已发布 | 需要有人写 formula |

结论：想**在配置里声明式长期管理**、或者要跑未发布的 commit → 用这个 flake；
只想在 macOS 上立刻试一下 → `npx @deepseek-ai/dsh web` 更省事。

## 文件

| 文件 | 作用 |
|---|---|
| `flake.nix` | 输入（nixpkgs / release 源码 / nightly 源码）与输出（packages、overlay、HM 模块、devShell、`.#update-hashes`） |
| `nix/dsh.nix` | 真正的 derivation：离线安装 → 构建 → 组装并校验运行时树 → wrapper |
| `nix/deploy-carrier.mjs` | 校验/修补运行时树：补全缺失依赖与 peer、实体化指向树外的链接、清理悬空链接、恢复 native helper 可执行位 |
| `nix/pnpm-deps.nix` | 固定输出抓取：pnpm store + 元数据缓存（离线构建的前提） |
| `nix/prepare-runtime.mjs` | 构建期小改动：去掉 `packageManager` 钉、为 deploy 开启 injection、删掉触发策略的 postinstall |
| `nix/hashes.json` | 依赖闭包 hash 注册表（按 lockfile 的 sha256 索引） |
| `nix/update-hashes.sh` | hash 登记脚本（`nix run .#update-hashes`） |
| `nix/home-manager.nix` | `programs.dsh.*` 模块 |

## License

打包脚本沿用上游仓库的 MIT 许可。
