# dsh.nix

从固定源码构建 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)，提供 CLI、Web、overlay 和 Home Manager 模块。

当前重构目标为 `0.1.5-rc.1` / `aarch64-darwin`。新方案的完整构建与运行验证进行中；旧 `result` 不代表当前代码已经通过。

```sh
nix build .#dsh
./result/bin/dsh --version
./result/bin/dsh web --no-open
```

## 构建方式

1. `nix/metadata/<lock-key>/` 保存上游 lockfile、workspace 配置的 JSON 和原文件 SHA-256。
2. Nix 按 lockfile 中每个 tarball 的 integrity 下载适用平台的依赖。
3. `prepare-runtime.py` 在源码副本中将 tarball URL 改为 Nix store 本地文件，并生成 Nix 专用 runtime manifest。必需的 workspace peer 在安装前显式声明。
4. 固定版本的 Node 和 pnpm 离线生成依赖 store，离线安装并执行上游 `pnpm run build`。
5. pnpm 部署 production 依赖。安装后只校验闭包，不复制缺失包；node-pty 的 helper 权限由上游脚本恢复。

逐包获取的设计参考 [Moraxyc 的 importPnpmLock](https://github.com/Moraxyc/deepseek-harness.nix/blob/main/pkgs/importPnpmLock/package.nix)。本仓库实现限定为 integrity 固定的 tarball；遇到 Git 或其他无法验证的依赖会明确失败。没有总 store 哈希登记步骤。

运行时使用 `apps/nix-runtime` 专用 manifest，不依赖 Python SDK bootstrap。CLI 和内置 bundle 由同一次 pnpm deploy 组装，以保留正确的版本解析和共享依赖关系。

## 更新源码和依赖元数据

```sh
# 修改 flake.nix 中 dsh-src 的 tag，然后更新锁定 revision。
nix flake update dsh-src

# SOURCE 是对应 revision 的干净源码目录。
nix run .#update-metadata -- /path/to/SOURCE
nix build .#dsh
```

元数据必须与源码中的 `pnpm-lock.yaml` 和 `pnpm-workspace.yaml` 一致；不一致会在求值时失败。`dsh-nightly` 保留为单独输出，也需要为其固定源码生成元数据。

覆盖源码时可以同时提供元数据目录：

```nix
dsh.override {
  src = mySource;
  dependencyMetadata = ./my-metadata;
}
```

`lib.<system>.mkDsh` 和 `mkDshFromPath` 保留。任意 revision 不保证兼容当前补丁和构建流程；升级后需重新验收。`runtimeNode`、`pnpmPackage` 可显式覆盖工具链，参数名避免与 `callPackage` 自动注入的 nixpkgs 属性冲突。

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

构建包含 CLI version/help 检查，以及运行时必需依赖和链接检查。完整运行检查使用临时 HOME / DSH_HOME，不需要 API key：

```sh
python3 nix/smoke-test.py ./result \
  --node "$(nix eval --raw .#dsh.node)/bin/node"
```

检查 CLI、实际 PTY 启动、Web 首页、manifest 和页面引用的静态资源。Web 检查在构建沙箱之外运行，因为它需要绑定本机回环端口。

首轮只声明 `aarch64-darwin` 支持。其他架构仍保留 flake 属性，但需相应平台验证后才启用；没有配置二进制缓存。
