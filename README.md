# MotionX

MotionX 2.2 的二进制语义重建工程。原包 com.hx.120，源 SHA256: 9cc469193bf5e8f5b73fbf21ce4f0c2d2036dbccc6e7040f9dd56f1f79c797fb。

恢复31个初始化/业务/辅助函数，另1个异常终止辅助由编译器生成。变量名和构建文件为重建，私有整数类型按 arm64 ABI 声明；不是原作者逐字源码。

无设置面板、无开关，按原过滤范围注入。请求120Hz显示参数与系统录屏120fps参数；实际刷新率/输出帧率需要真机测量。

GitHub Actions: macos-15，roothide/theos，SDK16.5，iOS15最低目标，arm64e单架构。产物在 Actions artifacts。

```sh
make clean package THEOS_PACKAGE_SCHEME=roothide ARCHS=arm64e
```

原control作者信息、包标识与安装脚本用于来源追溯保持。版本由CI设为5.2.0-run_number。postinst终止replayd/backboardd，postrm终止replayd。
