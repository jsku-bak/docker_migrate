# 🐳 Docker Migrate

面向个人服务器和轻量运维场景的一键 Docker 迁移工具。它会备份容器配置、镜像、命名卷、绑定目录、Compose 项目和自定义网络，并在目标服务器自动恢复。

## 功能

- 交互式选择独立容器或 Compose 项目，也支持 `--include` 精确选择。
- 迁移镜像、命名卷、绑定目录、端口、环境变量、健康检查和资源限制。
- 保存自定义网络的 driver、IPAM、子网、网关、IPv6、options 和 labels。
- Compose 多文件合并恢复，保留相对目录和 `env_file`。
- 备份失败时停止生成迁移包，避免空卷或不完整数据被误认为成功。
- 自动恢复源服务器上原本处于运行状态的容器。
- 自动生成并验证 SHA-256 清单，无需增加用户操作。

## 快速使用

### 1. 在旧服务器备份

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/lx969788249/docker_migrate/master/docker_migrate_perfect.sh)
```

选择“备份容器并传输”，按提示选择容器。脚本完成打包后会输出下载链接。

### 2. 在新服务器恢复

运行同一条命令，选择“下载备份并恢复”，粘贴链接即可。

也可以直接使用非交互模式：

```bash
bash docker_migrate_perfect.sh --restore='http://旧服务器:端口/随机路径/迁移包.tar.gz'
```

备份指定容器：

```bash
bash docker_migrate_perfect.sh --backup --include=nginx,mysql
```

## 恢复策略

目标服务器存在同名独立容器时，默认删除并按迁移包完整重建，确保镜像、环境变量、挂载、网络和资源限制一致。

可以通过环境变量改变策略：

```bash
RESTORE_EXISTING=replace  # 默认：替换并完整恢复
RESTORE_EXISTING=skip     # 保留并跳过同名容器
RESTORE_EXISTING=fail     # 发现同名容器立即失败
```

恢复过程中只要命名卷、绑定目录或网络预检失败，就不会继续启动相关容器。失败文件默认保留，方便排查。

## 无感安全增强

项目仍保留复制链接即可恢复的体验：

- 临时包默认仅当前用户可读。
- URL 使用随机路径；Python 和 BusyBox HTTP 模式都会保留随机路径。
- 每个迁移包包含 SHA-256 清单，下载后自动验证。
- 解压前检查危险路径和顶层链接，卷及绑定目录归档也会做路径检查。
- HTTP 响应禁止缓存，并以附件形式下载。

HTTP 仍是明文传输，SHA-256 清单用于发现损坏或意外修改，并不提供发送方身份认证。请继续只在可信网络、临时防火墙规则或私有网络内使用。

## 兼容性

- Linux：Bash 4+，支持 apt、dnf、yum、zypper、apk。
- macOS：需要 Homebrew Bash；脚本不再强制依赖 GNU `flock`、`sed -i`、`timeout` 或 `grep -P`。
- Docker Engine / Docker Desktop；Compose Plugin 优先，兼容 `docker-compose` v1。

对于 macOS Apple Silicon，通常使用：

```bash
/opt/homebrew/bin/bash docker_migrate_perfect.sh
```

## 测试

仓库包含静态检查、单元测试和真实 Docker 恢复测试：

```bash
bash -n docker_migrate_perfect.sh tests/*.sh
shellcheck -S warning docker_migrate_perfect.sh tests/*.sh
tests/lint-generated.sh
tests/run.sh
tests/integration_docker.sh
```

GitHub Actions 会运行同样的检查。Docker 集成测试会验证：

- 0.5 CPU 限制不会被整数截断；
- 健康检查正确恢复；
- 自定义网络、子网和静态 IP 正确恢复；
- `replace`、`skip`、`fail` 三种同名容器策略。

## 注意事项

- 数据库等有状态服务建议选择停机备份。
- `--no-stop` 可能产生应用层不一致数据。
- macvlan、ipvlan、overlay、第三方 volume/network driver 仍依赖目标服务器具备相同环境。
- 恢复会写入原绑定目录和 Compose 工作目录，请先确认目标服务器路径不会与其他业务冲突。
- 旧版不含校验清单的迁移包仍可恢复，但会显示兼容模式警告。
