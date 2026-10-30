# CLAUDE.md

> **本文件本应是 `AGENTS.md` 的符号链接，当前为指针文件。**
>
> 原因：这台 Windows 机器未启用「开发者模式」，创建软链被系统拒绝
> （`ln: Operation not permitted` / `mklink: 你没有足够的权限执行此操作`）。
>
> 内容以 [AGENTS.md](AGENTS.md) 为准；两者若不一致，**永远以 AGENTS.md 为准**。

启用「设置 → 隐私和安全性 → 开发者选项 → 开发人员模式」后，可换成真正的软链：

```bash
rm CLAUDE.md
MSYS=winsymlinks:nativestrict ln -s AGENTS.md CLAUDE.md
test -L CLAUDE.md && echo "已是符号链接"
```

@AGENTS.md
