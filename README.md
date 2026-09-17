# dsh.nix

从固定源码构建 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)，提供 CLI、Web、overlay 和 Home Manager 模块。

```sh
nix build .#dsh
./result/bin/dsh --version
./result/bin/dsh web --no-open
```

## 当前状态

- 已验证版本：`0.1.5-rc.1`（`dsh-src` 锁定 `183f08e9`）。
- 已验证平台：`aarch64-darwin`。其他架构保留 flake 属性，但没有构建和运行验证，因此不声明支持。
- `dsh-nightly`（`0.1.6-alpha.1`）有元数据、可求值，但本轮没有做运行验收。
- 没有二进制缓存。

## 构建方式

1. `nix/metadata/<lock-key>/` 保存上游 `pnpm-lock.yaml`、`pnpm-workspace.yaml` 的 JSON 形式，以及两个原文件的 SHA-256 和版本号。**这些文件已提交进 git**：`nix build` 只把已跟踪文件复制进 store，元数据不入库就无法干净构建。
2. Nix 按 lockfile 中每个 tarball 的 integrity 逐包下载本平台适用的依赖，没有任何占位哈希。
3. `prepare-runtime.py` 在源码副本中把 tarball 指向本地文件、生成 Nix 专用运行时 manifest 与其 lockfile importer，并对上游 workspace 配置做两处具名的窄改写（见下）。
4. 固定版本的 pnpm 与 Node 在离线状态下生成依赖 store、离线安装并执行上游 `pnpm run build`。
5. `pnpm deploy --prod --node-linker=hoisted` 组装自包含运行时；`verify-runtime.mjs` 只校验、不补齐——缺依赖就构建失败。

`pnpm` 运行在 Node 22 上，而安装出来的 `dsh` 运行在 Node 24 上（`runtimeNode`）。这是刻意的：在构建沙箱里用 Node 24 跑 `pnpm install` 会在安装结束时以 `Assertion failed: (errno == EINTR), function uv__io_poll, file kqueue.c` 中止，Node 22 同样的安装不会。`pnpmNode` 可覆盖这一项。

逐包获取的设计参考 [Moraxyc 的 importPnpmLock](https://github.com/Moraxyc/deepseek-harness.nix/blob/main/pkgs/importPnpmLock/package.nix)，并限定为 integrity 固定的 tarball：遇到 Git 或其他无法校验的依赖会明确失败。

### 为什么改写上游 workspace 配置

上游 `package.json` 钉的是 `pnpm@11.7.0`，本仓库钉 `11.25.0`。11.25 对 `pnpm-workspace.yaml` 的校验更严，因此 `prepare-runtime.py` 会精确改写两类记录（各有回归测试）：

| 改写 | 原因 |
|---|---|
| 删除 `minimumReleaseAgeExclude` 中指向 workspace 链接的 `@file:` 条目 | 该设置只对 registry 包的发布时间有意义；11.25 会以 `ERR_PNPM_INVALID_VERSION_UNION` 直接失败 |
| 把 `allowBuilds` 的 `@file:` 键归一到裸包名 | 同上，保留原有的 true/false 决定 |

此外还会：删除 `packageManager`（改由 Nix 固定 pnpm）、加上 `injectWorkspacePackages`（`pnpm deploy` 必需，pnpm 只从该文件读取）、去掉 `subprocess-local` 的源码侧 postinstall（其操作改为部署后对运行时副本执行）。

## 更新源码和依赖元数据

```sh
# 1. 修改 flake.nix 中 dsh-src 的 tag，然后更新锁定 revision。
nix flake update dsh-src

# 2. 同步依赖元数据：报告 flake 锁定的源、lockKey 与该目录是否最新，
#    需要时直接重新生成。幂等，可以随时重跑。
nix/update-metadata-for-input.sh          # 两个输出都检查
nix/update-metadata-for-input.sh dsh      # 只检查固定版本

# 3. 构建并提交：flake.lock 与 nix/metadata 必须在同一次提交里。
nix build .#dsh .#dsh-nightly
python3 nix/smoke-test.py ./result --node "$(nix eval --raw .#dsh.node)/bin/node"
```

完整的升级流程、失败症状对照表和注意事项见 **[MAINTAINING.md](./MAINTAINING.md)**。

元数据的 `source.json` 记录格式版本和 lock/workspace 的 SHA-256；与源码不一致或格式过旧都会在求值阶段明确失败。一个新 tag 不一定改 lock，此时 `lockKey` 不变、无需重新生成，脚本只会提醒记录的版本号需要跟着走。

覆盖源码时可以同时提供元数据目录：

```nix
dsh.override {
  src = mySource;
  dependencyMetadata = ./my-metadata;
}
```

`lib.<system>.mkDsh` 和 `mkDshFromPath` 保留。任意 revision 不保证兼容当前补丁和构建流程；源码与元数据不匹配时会报错，而不是产出不可用的构建。`runtimeNode`、`pnpmPackage` 可显式覆盖工具链。

## Home Manager

```nix
{
  imports = [ inputs.dsh.homeManagerModules.default ];
  programs.dsh = {
    enable = true;
    # home = "/home/alice/.dsh";
    # pluginManager = true; # 将 pnpm 放入 PATH，用于插件管理
  };
}
```

也可以使用 `overlays.default` 提供的 `pkgs.dsh` 和 `pkgs.dsh-nightly`，或直接安装 `packages.<system>.dsh`。

## 验证

构建的 `installCheckPhase` 只检查 CLI 的 `--version` / `--help`。完整运行检查在构建沙箱之外执行，需要临时 `HOME`/`DSH_HOME`，不需要 API key：

```sh
nix build .#dsh
python3 nix/smoke-test.py ./result \
  --node "$(nix eval --raw .#dsh.node)/bin/node"
```

`smoke-test.py` 检查三件事：

1. CLI：`--version` 等于构建版本，`--help` 正常退出。
2. PTY：用运行时自己的 `node-pty` 真实创建终端并执行命令、读到输出。
3. Web：临时目录下启动 `dsh web --no-open`，跟随 CLI 打印的带 token URL（换取会话 cookie）抓取首页，再抓取页面实际引用的每个 `/assets/*` 与 `manifest.webmanifest`。

`verify-runtime.mjs` 在构建内运行，沿运行时实际可达的依赖图检查必需依赖能否解析、链接是否逃逸出运行时，以及 `lib/bin.js` 与前端 `dist/index.html` 是否存在。它只报错，不修复；依赖缺失必须回到 manifest 解决。
