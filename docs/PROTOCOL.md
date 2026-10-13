# GX85 无线协议与兼容性

实现使用相机已有的无线遥控能力，不修改相机固件。接口来自第三方协议记录，不是松下承诺稳定的公开开发 SDK。

## 命令与画面

HTTP 控制入口为相机地址下的 `/cam.cgi`。当前实现包括访问许可、状态读取、进入拍摄模式、启动/停止取景流和快门。XML 正文的直接 result 字段或逗号文本的首字段才决定相机是否接受；HTTP 200 本身不代表操作成功。

监看通过相机发来的 UDP 单播数据，默认接收端口 49152。监听绑定成功后才发送启流命令。解析器寻找 JPEG 边界，限制不完整帧长度与存活时间；不依赖固定厂商头长度，不宣称支持任意乱序分片重建。

## 握手标识

部分参考实现的 `req_acc` 请求使用相机 UPnP 描述中的 UDN。App 首先向已输入的相机 IP 发出单播 SSDP 搜索，验证回应的描述地址仍是同一相机，再读取 UDN 并缓存。此过程不扫描附近设备、不发 iOS 多播包。

相机若不回应单播，App 会尝试持久的本机标识。该兼容尝试尚未在本用户 GX85 上验证；失败时可以手动设置相机 UDN：

1. 暂时断开 iPhone 与相机的控制会话，在相机重新开启遥控连接。
2. 将 Windows 电脑连到相机的 Wi-Fi。
3. 在工程目录的 PowerShell 中运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\camera-identity.ps1 -CameraIP 192.168.54.1
```

4. 脚本只搜索并读取描述，不发送拍照指令；记录输出标识。
5. 电脑断开相机 Wi-Fi，iPhone 重新加入，在 App 设置 → 高级连接设置中填入标识，再连接。

脚本使用桌面 SSDP 多播，同时只接受指定相机地址的回应。多网络适配器、防火墙或相机未回应会使搜索失败；失败时需要结合真机网络记录进一步排查，不能保证所有固件会接受默认标识。

## 本地 HTTP

为兼容 iOS 16 起的数字 IP 明文 HTTP，Info.plist 使用 `NSAllowsArbitraryLoads`。应用实际请求仅由校验后的相机 IPv4 地址生成；UPnP 描述地址和 HTTP 重定向也限制在同一相机。没有浏览器、广告、分析上报或其他联网业务。以后增加互联网功能时应重新收紧和拆分网络策略。

## 资料来源

- [松下 GX80/GX85 遥控说明](https://av.jpn.support.panasonic.com/support/spn/global/dsc/help/image_app/en/camera/DMC-GX80_GX85/remote.html?no=1)：支持功能及模式限制。
- [GMaster](https://github.com/Rambalac/GMaster)：第三方 GX85 支持记录，以及其握手、UDP 流形态的参考。
- [lumixproto](https://github.com/cleverfox/lumixproto)：GX80 命令行为的第三方记录。
- [free-wireless-hdmi](https://github.com/steveseguin/free-wireless-hdmi)：JPEG 流与快门的参考。
- [Apple 本地网络隐私 TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)：iOS 单播、多播与本地网络权限。

本工程没有复制上述项目源码。GX85 固件的身份握手、数据包格式、拍摄后停流与恢复行为仍需真机核实。
