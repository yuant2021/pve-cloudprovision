# pve-cloudprovision

Proxmox VE 9 的云服务器创建插件：从集群中的任意 QEMU 模板创建虚拟机，创建时自选 CPU、内存、
系统盘/数据盘和任意数量的网卡，每块网卡单独配置路由 IP（[pve-routedip](../pve-routedip)，
任意长度 CIDR）、限速、流量配额（[pve-trafficd](../pve-trafficd)），虚拟机内的 IP 由 cloud-init
按路由 IP 自动配置。支持重装系统（换模板、保留参数）和迁移。

## 功能

- **自动识别模板**：集群内所有 QEMU 模板（`template: 1`）都可直接使用，API 返回模板的节点、
  CPU/内存、启动盘及大小、存储、是否有 cloud-init 盘、是否在共享存储上。
- **创建**（与 Create VM 平级：页面顶栏和节点右键菜单中的 “Create Cloud Server”）：
  - CPU（核数、插槽、CPU 类型）、内存（及最小内存）、系统盘大小（只能比模板大）、存储、
    数据盘（任意个，大小/存储），完整克隆或链接克隆；
  - 任意数量的网卡（`net0`、`net1`…），每块网卡：网桥、VLAN、型号、MAC、防火墙、
    **限速**（PVE 网卡 `rate`，MB/s）、**路由 IP**（pve-routedip：CIDR 列表、tap-only、rp_filter、网关覆盖）、
    **流量**（pve-trafficd：计数、配额、超额后的限速值、计数方向）、**虚拟机内 IP**（cloud-init）；
  - cloud-init：用户、密码、SSH 公钥、DNS、是否升级软件包；名称即主机名，默认 `vm<VMID>`；
  - 模板没有 cloud-init 盘时自动添加一个；模板的备注（描述）不带到新服务器上；
  - 新服务器从干净的状态开始：该 VMID 上已删除虚拟机残留的 pve-routedip / pve-trafficd 配置
    （pve-trafficd 有意为重建保留的计数和限速）在克隆前被清除。要保留它们请用重装。
- **虚拟机内 IP 自动生成**：每块网卡、每个地址族取该网卡**第一个**对应地址族的路由 CIDR：
  `/32`、`/128` 直接使用该地址，其它长度（如 `/29`、`/64`）使用网络地址之后的第一个地址
  （`203.0.113.0/29` → `203.0.113.1`，`2001:db8::/64` → `2001:db8::1`），以主机前缀（`/32`、`/128`）
  配置，网关为 pve-routedip 对该网卡生效的宿主网关（默认 `169.254.0.1`、`fe80::1`），即
  `ipconfigN: ip=203.0.113.1/32,gw=169.254.0.1,ip6=2001:db8::1/128,gw6=fe80::1`。
  网卡参数 `ip`/`gw`/`ip6`/`gw6` 可按地址族覆盖（例如 `ip=dhcp`、`ip6=auto`）。
  没有路由 IP 也没有指定 IP 的网卡不设置 `ipconfigN`（沿用模板同序号网卡的设置）。
- **重装系统**：保存当前参数，用（新的）模板重新创建，恢复参数：
  - 系统盘（来自模板的磁盘，含 EFI/TPM 盘）换成新模板的，大小恢复为原系统盘大小（新模板更大时用新模板的）；
  - 保留：名称、描述、标签、开机启动、CPU、内存、全部网卡（含 MAC 地址）、cloud-init 设置
    （可在重装时修改用户/密码/SSH 公钥）、数据盘、未使用的磁盘、直通设备、SMBIOS UUID；
  - 其余（BIOS、机型、OS 类型、SCSI 控制器、显示、串口、启动顺序……）来自新模板；
  - 虚拟机 VMID 始终存在，所以路由 IP、流量计数与限速状态、防火墙规则、权限、资源池、
    备份/复制任务都不受影响；
  - 自动生成的 `ipconfigN` 按当前路由 IP 重新生成（重装前改过路由 IP 的，新系统直接用新地址），
    手工改过的 `ipconfigN` 保持不变；
  - 运行中的虚拟机先关机，重装后启动（可选）；
  - 失败时：替换磁盘之前失败的，虚拟机保持原样（原来在运行的重新启动）；保存的参数在
    `/etc/pve/cloudprovision/<vmid>.json` 中。
- **迁移**：
  - 创建/重装时模板可以在任何节点上：模板在本节点，或模板和目标存储都是共享存储时直接克隆；
    否则在模板所在节点克隆，再（离线）迁移到目标节点，磁盘迁移到目标存储；
  - 云服务器是普通的 PVE 虚拟机，可照常在线/离线迁移，路由 IP 与流量统计随之迁移（依赖插件负责）；
  - 虚拟机相关的 API 请求自动转发到虚拟机当前所在节点。
- **API、命令行、Web 界面**，见下文。
- **可安装、可卸载**：标准 deb 包，依赖 pve-routedip、pve-trafficd。卸载时恢复被替换的 PVE 文件，
  已创建的虚拟机不受影响。

只支持 QEMU 虚拟机。

## 安装

所有节点都需要安装（pve-routedip、pve-trafficd 也是）：

```sh
make deb                      # 需要 debhelper、libpve-common-perl
apt install ./pve-cloudprovision_1.0.0_all.deb
```

pvedaemon、pveproxy 由 PVE 的 `pve-api-updates` 触发器自动重载，刷新浏览器即可看到新按钮和页面。

卸载：`apt remove pve-cloudprovision`。`/etc/pve/cloudprovision/` 是集群共享的，卸载与 purge 都不会删除它。

## 模板

任何 QEMU 模板都可以，云镜像需要 cloud-init（nocloud）。例如：

```sh
qm create 9000 --name debian-13-cloud --ostype l26 --memory 1024 --cores 1 \
    --scsihw virtio-scsi-single --net0 virtio,bridge=vmbr0 --serial0 socket --vga serial0
qm set 9000 --scsi0 local-lvm:0,import-from=/root/debian-13-genericcloud-amd64.qcow2,discard=on
qm set 9000 --ide2 local-lvm:cloudinit --boot order=scsi0
qm template 9000
```

虚拟机内的 IPv4 网关（`169.254.0.1`）不在 `/32` 网段内，系统内必须以 on-link 方式添加默认路由。
较新的 cloud-init（例如 Debian 13 的 25.x）在网关不在子网内时自动给 netplan 写 `on-link: true`，
可以直接使用（Debian 13 genericcloud 已验证）。Debian 12 genericcloud 镜像的 cloud-init 22.4 只写
`gateway4:`，其 systemd-networkd 不会安装这条默认路由：IPv4 不通（IPv6 网关 `fe80::1` 是链路本地地址，
不受影响，已验证）。这类镜像请换用自带较新 cloud-init 的版本，或在虚拟机内自行添加
`ip route add default via 169.254.0.1 dev eth0 onlink`。

## 使用

Web 界面：

- 顶栏 / 节点右键菜单 → **Create Cloud Server**：常规（节点、VMID、名称、资源池）→ 模板（模板、存储、
  系统盘大小）→ 硬件（CPU、内存、数据盘）→ 网络（网卡列表，每块网卡的路由 IP、虚拟机内 IP 预览、
  限速、流量）→ Cloud-Init → 确认。
- 虚拟机 → **Cloud Server**：模板、创建/重装时间、状态、系统盘，各网卡的路由 IP、cloud-init IP、配额；
  **Reinstall** 按钮（选择模板，可改密码/SSH 公钥，需输入 VMID 确认）。
- 数据中心 → **Cloud Servers**：集群内全部云服务器和模板。

命令行（`pve-cloudprovision`，在虚拟机所在节点执行）：

```sh
pve-cloudprovision templates
pve-cloudprovision create 9000 --name web1 --cores 2 --memory 2048 --disksize 20 \
    --net0 'vmbr0,cidr=203.0.113.10;2001:db8:10::/64,tap-only=1,rate=12.5,quota=1T' \
    --net1 'vmbr1,ip=dhcp' --datadisk0 50 \
    --ciuser debian --sshkeys ~/.ssh/id_ed25519.pub
pve-cloudprovision list
pve-cloudprovision show 100
pve-cloudprovision reinstall 100 --template 9001 --cipassword 'new-secret'
pve-cloudprovision sync-ipconfig 100
```

### 网卡参数（`netN`）

属性字符串，第一个值是网桥：`vmbr0,cidr=203.0.113.0/29;2001:db8::/64,tap-only=1,rate=10,quota=500GB`

| 键 | 说明 |
|---|---|
| `bridge` | 网桥 / SDN VNet（默认键） |
| `model`、`macaddr`、`tag`、`firewall`、`mtu`、`queues` | 同 PVE 网卡；`model` 默认 `virtio`，MAC 默认随机 |
| `rate` | 限速，MB/s（PVE 网卡 `rate`） |
| `cidr` | 路由 IP，`;` 分隔，任意前缀长度（pve-routedip） |
| `tap-only`、`rp-filter`、`gateway4`、`gateway6` | pve-routedip 的网卡设置 |
| `ip`、`gw`、`ip6`、`gw6` | 虚拟机内 IP（cloud-init），不填则由 `cidr` 生成 |
| `traffic` | 统计流量（pve-trafficd），设置了 `quota`/`quota-rate`/`direction` 时自动开启 |
| `quota` | 流量配额：字节数或 `K M G T P`（1024）/ `KB MB GB TB PB`（1000） |
| `quota-rate` | 达到配额后的限速值，MB/s（默认 pve-trafficd 集群设置） |
| `direction` | 计入配额的方向：`both`、`in`、`out`、`max` |

给出任意 `netN` 时，模板的网卡被替换；不给则保留模板的网卡。

数据盘（`datadiskN`）：`<GiB>[,storage=<存储>]`，挂在系统盘的总线上，存储默认同系统盘。

### API

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/nodes/{node}/cloudprovision/templates` | 集群内全部模板；`direct`：在该节点上是否直接克隆（否则克隆后迁移） |
| GET | `/nodes/{node}/cloudprovision/servers` | 集群内全部云服务器（`state`、`template`、`created`、`reinstalled`…） |
| POST | `/nodes/{node}/cloudprovision` | 在该节点创建云服务器，返回任务 UPID |
| GET | `/nodes/{node}/qemu/{vmid}/cloudprovision` | 云服务器状态、系统盘、各网卡（路由 IP、cloud-init IP、配额）、上次重装保存的参数 |
| POST | `/nodes/{node}/qemu/{vmid}/cloudprovision/reinstall` | 重装：`template`（默认上次的）、`storage`、`full`、`ciuser`、`cipassword`、`sshkeys`、`start`，返回任务 UPID |
| POST | `/nodes/{node}/qemu/{vmid}/cloudprovision/ipconfig` | 按当前路由 IP 重新生成各网卡的 `ipconfigN`（手工改过的也覆盖，记为自动生成）并重新生成 cloud-init 盘，返回任务 UPID；虚拟机下次启动时应用 |

`/nodes/{node}/qemu/{vmid}/cloudprovision…` 自动转发到虚拟机当前所在的节点。

权限：

- 创建：`/vms/{vmid}`（或资源池）上的 `VM.Allocate` 与 `VM.Config.*`（启动还需 `VM.PowerMgmt`），
  模板上的 `VM.Clone`，存储上的 `Datastore.AllocateSpace`，网桥的 `SDN.Use`；
  配置路由 IP 或流量统计时还需 `/` 上的 `Sys.Modify`（与 pve-routedip、pve-trafficd 相同）。
- 重装：虚拟机上的 `VM.Allocate`、`VM.Config.Disk`、`VM.Config.Cloudinit`、`VM.PowerMgmt`，
  模板上的 `VM.Clone`，存储上的 `Datastore.AllocateSpace`。
- 同步 ipconfig：虚拟机上的 `VM.Config.Cloudinit`。
- 读：`VM.Audit`（模板列表也接受 `VM.Clone`）。

权限检查通过后，任务以 root@pam 执行（克隆、迁移等调用 `qm`，其它节点经 SSH）。

## 文件

```
/etc/pve/cloudprovision/<vmid>.json   云服务器状态：模板、创建/重装时间、系统盘、
                                      自动生成的 ipconfig、进行中的任务、重装保存的参数
```

## 实现说明

- 创建：先清除该 VMID 残留的 pve-routedip / pve-trafficd 配置（虚拟机不存在时），`qm clone`（必要时在模板
  节点克隆再 `qm migrate`），再用 `PUT /config`（进程内调用）设置 CPU、内存、网卡、`ipconfigN`、cloud-init、
  数据盘、启动顺序，`qm disk resize` 扩大系统盘，调用 pve-routedip、pve-trafficd 的 API 写入网卡配置，最后启动。
  失败时删除已创建的虚拟机和写入的配置。
- 重装：给虚拟机加 `create` 锁并关机，把新模板克隆到一个临时 VMID（`cloudprovision-staging-<vmid>`，
  需要时迁移到虚拟机所在节点），然后在两个虚拟机的配置锁下交换：临时虚拟机的磁盘
  改名（`rename_volume`）归入原 VMID，原虚拟机的配置换成模板配置加保留的参数，释放旧系统盘和
  旧 cloud-init 盘；删除临时虚拟机，添加 cloud-init 盘，扩大系统盘，解锁并启动。
  被中断的重装留下的临时虚拟机在下次重装时删除。
- 系统盘：记录在状态文件中（创建/重装时来自模板的磁盘）；没有记录的虚拟机（非本插件创建）按
  启动盘 + `efidisk0` + `tpmstate0` 处理。
- API 注册：安装时用 `dpkg-divert` 替换 `PVE/API2/Nodes.pm`（pve-manager），替换后的模块原样加载原文件，
  再注册 `/nodes/{node}/cloudprovision` 与 `/nodes/{node}/qemu/{vmid}/cloudprovision`。不注册 `/cluster` 下的路径：
  `PVE::API2::Cluster` 加载完成之前就会加载 `PVE::API2::Nodes`。pve-routedip 替换 `PVE/API2.pm`、`PVE/Network.pm`，
  pve-trafficd 替换 `PVE/API2/Cluster.pm`，互不冲突。Web 界面通过在 `index.html.tpl` 中插入 script 标签加载，
  pve-manager 升级后由 dpkg 触发器重新插入。

## 限制

- 重装要求虚拟机没有快照、未开启保护、没有对磁盘的待生效（pending）修改，HA 状态不能是 `started`。
- 链接克隆只能在模板所在节点创建，或模板在共享存储上；跨节点的离线迁移要求源、目标存储类型
  之间能迁移磁盘（PVE 的限制）。
- 虚拟机内的 IPv4 网关（`169.254.0.1`）不在 `/32` 子网内，需要 cloud-init 渲染为 on-link 路由
  （见上文“模板”，Debian 12 自带的 cloud-init 22.4 不会）。
- cloud-init 只在虚拟机首次启动（新系统盘）时生效，创建后修改路由 IP 不会改变运行中系统内的地址，
  重装时才按新路由 IP 生成。同步 ipconfig（`…/cloudprovision/ipconfig`）后，虚拟机下次启动时 cloud-init
  因配置变化把这次启动当作新实例：应用新地址，同时重新设置密码（恢复为 `cipassword`）、重新生成 SSH 主机密钥。
- 所有节点都要安装三个插件。

## 开发

```sh
make check    # 单元测试，需要 libpve-common-perl
make deb
PROJECT=pve-cloudprovision ~/pve-lab/deploy.sh   # 在 lab 的 chroot 中构建并安装到 pve1、pve2
```
