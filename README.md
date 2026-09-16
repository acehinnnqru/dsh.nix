# dsh.nix

把 [deepseek-harness](https://github.com/deepseek-ai/deepseek-harness)（`dsh`）从源码构建成 Nix 包，
用来声明式安装、并且可以随意切换版本（release tag / nightly / 任意 commit / 本地 checkout）。

```sh
nix run github:acehinnnqru/dsh.nix          # 直接跑
nix profile install github:acehinnnqru/dsh.nix
```

## 它是怎么构建的

Nix 里跑的就是仓库自己的构建流程，产物是仓库所谓的 **node carrier**（不是自带 Node 的单文件 exe）：

1. `pnpm install --offline --frozen-lockfile` —— 依赖来自 `fetchPnpmDeps` 的固定输出（FOD）store，
   由 nixpkgs 的 pnpm setup hook 自动完成，构建期不联网。
2. `pnpm run build` —— 原生 `flock` addon（用 Node headers 编译 C）、Host/Client 两个 TypeScript
   aggregate、tsdown 打包、Vite 构建 Web 前端。
3. `pnpm --filter dsh-python-runtime-closure deploy --legacy --prod` —— 用仓库自己的
   runtime closure 清单（`python/sdk-runtime/package.json`）部署出只含生产依赖的树；
   `nix/deploy-carrier.mjs` 再把 pnpm 留下的符号链接实体化（`.bin` 直接删掉），
   得到一棵可重定位、放进 store 也不会断链的运行时树。
4. `makeWrapper <nixpkgs node> $out/bin/dsh --add-flags $out/lib/dsh/runtime-bootstrap.mjs`。

所以运行时的 Node 来自 nixpkgs（`dsh.node`，当前为 nodejs_24），`dsh` 本体只有几百 MiB 的 JS/native 依赖树。

## 用法

### nix-darwin / NixOS（overlay）

```nix
{
  inputs.dsh.url = "github:acehinnnqru/dsh.nix";

  # 在你的 configuration 里
  nixpkgs.overlays = [ inputs.dsh.overlays.default ];

  environment.systemPackages = [
    pkgs.dsh          # release（跟 dsh-src 输入，默认 dsh-v0.1.5-rc.1）
    # pkgs.dsh-nightly  # 跟 main 分支
  ];
}
```

用 overlay 的好处是它使用**你自己的 nixpkgs**，不会多出一份 node/pnpm 版本。

也可以不用 overlay，直接引用 flake 的包：

```nix
environment.systemPackages = [ inputs.dsh.packages.${pkgs.system}.dsh ];
```

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
nix flake check      # 构建 dsh 作为 check
```

## 切换版本

**1. 换 release tag**（或任何 ref）：

```sh
# 不改文件，直接改 flake.lock 里的输入
nix flake lock --override-input dsh-src github:deepseek-ai/deepseek-harness/dsh-v0.1.5-rc.2

nix run .#update-hashes -- dsh   # 新 revision 需要登记依赖 hash（见下一节）
nix build .#dsh
```

或者把 `flake.nix` 里的 `dsh-src.url` 改成新的 tag/branch/rev，再 `nix flake update dsh-src`。

**2. nightly**：`packages.<system>.dsh-nightly` 固定跟踪 `master`，
用 `nix flake update dsh-nightly-src` 前进到最新。

**3. 任意 revision / 本地 checkout**：flake 暴露了 `lib.<system>.mkDsh`：

```nix
let
  dshLib = inputs.dsh.lib.${pkgs.system};
in {
  # 任意 commit（用 fetchTree / fetchFromGitHub 钉住）
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
  ];

  # 或者直接用本地目录（未提交的改动也会生效，自动排除 node_modules/.git）
  # environment.systemPackages = [ (dshLib.mkDshFromPath /Users/rqc/r/github.com/deepseek-ai/deepseek-harness) ];
}
```

已经用了 overlay 的话等价写法是 `pkgs.dsh.override { src = ...; }`。

## 依赖 hash 是怎么维护的

Nix 需要 `pnpm-lock.yaml` 那个依赖闭包的固定散列。`nix/hashes.json` 按
**lockfile 自身的 sha256 前 16 位**索引，所以同一份 lockfile 只登记一次，多个 revision 可以共存：

```json
{
  "a6515566578a26c2": {
    "version": "0.1.5-rc.1",
    "hashes": { "aarch64-darwin": "sha256-..." }
  }
}
```

没有登记的 revision 会用占位 hash 构建，Nix 因此报错并打印它算出来的真实 hash；
`nix run .#update-hashes` 会自动跑一遍、读回 hash、写进 `nix/hashes.json`：

```sh
nix run .#update-hashes                    # dsh + dsh-nightly，当前系统
nix run .#update-hashes -- dsh-nightly     # 只更新一个
DSH_NIX_SYSTEM=x86_64-linux nix run .#update-hashes -- dsh   # 需要该平台的 builder
```

hash 是**按平台**的（pnpm 只为当前平台拉 optional 依赖，比如 `@esbuild/*`、`@vscode/ripgrep-*`），
所以每个平台第一次都要跑一次上面的命令。本仓库已登记 `aarch64-darwin`。

## 已知限制

- 首次构建要下载整个 monorepo 的依赖并跑完整构建（tsc + tsdown + vite），比较慢；
  之后换 revision 时依赖没变就直接复用 store。
- 运行时需要 nixpkgs 的 Node 24（由 wrapper 固定，不用系统 Node）。
- `dsh plugin ...` 需要 pnpm 在 PATH 上（HM 的 `pluginManager = true`，或
  `pkgs.dsh.override { extraRuntimePath = [ pkgs.pnpm ]; }`）。
- 每次换 revision 都要登记一次依赖 hash。

## 为什么用 Nix 而不是 brew / npx

三者不冲突，用途不同：

| | Nix（本仓库） | `npx @deepseek-ai/dsh web` | Homebrew formula |
|---|---|---|---|
| 声明式、可回滚 | ✅ `flake.lock` 钉死，`nix profile rollback` | ❌ | ⚠️ 版本跟着 formula 走 |
| 钉任意 commit / 本地源码 | ✅ `mkDsh` / `mkDshFromPath` | ❌ 只能装已发布版本 | ❌ |
| 跨机器一致（macOS + Linux） | ✅ 同一份定义 | ⚠️ 各自 `npm install` | ⚠️ macOS/Linux 两套 formula |
| 与 nix-darwin / HM 集成 | ✅ | ❌ | ⚠️ 只能 `brew bundle` |
| 上手成本 | 中（首次构建慢） | 最低 | 低 |
| 是否需要维护者发版 | ❌ 自己从源码构建 | 需要 npm 已发布 | 需要有人写 formula |

结论：想**在配置里声明式长期管理**、或者要跑未发布的 commit → 用这个 flake；
只想在 macOS 上立刻试一下 → `npx @deepseek-ai/dsh web` 更省事。brew 在本机已经有 nix-darwin 的情况下
没有额外收益（`brew` 装的东西无法被 nix 配置引用，版本也不受 `flake.lock` 约束）。

## 文件

| 文件 | 作用 |
|---|---|
| `flake.nix` | 输入（nixpkgs / release 源码 / nightly 源码）与输出（packages、overlay、HM 模块、devShell、`.#update-hashes`） |
| `nix/dsh.nix` | 真正的 derivation：离线安装 → 构建 → deploy → 去符号链接 → wrapper |
| `nix/deploy-carrier.mjs` | 把 `pnpm deploy` 的输出变成无符号链接的运行时树（对应仓库 `scripts/build-exe-for-python-sdk.ts` 中的 deploy 阶段） |
| `nix/hashes.json` | 依赖闭包 hash 注册表 |
| `nix/update-hashes.sh` | hash 登记脚本（`nix run .#update-hashes`） |
| `nix/home-manager.nix` | `programs.dsh.*` 模块 |

## License

打包脚本沿用上游仓库的 MIT 许可。
