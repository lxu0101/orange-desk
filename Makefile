# 橙子：make 一步装好（编译 + 生成配置 + 准备工作区）
WORKDIR ?= $(HOME)/Orange
APP := 橙子.app

.PHONY: all build setup check open clean

all: check build setup
	@echo "✅ 装好了。双击 $(APP) 启动，或运行 make open"

check:
	@xcode-select -p >/dev/null 2>&1 || { echo "❌ 没装 Xcode 命令行工具：运行 xcode-select --install，在弹窗里点「安装」，装完再 make"; exit 1; }
	@command -v swiftc >/dev/null || { echo "❌ 找不到 swiftc，请重新安装 Xcode 命令行工具"; exit 1; }

build:
	mkdir -p "$(APP)/Contents/MacOS"
	swiftc -O Orange.swift -o "$(APP)/Contents/MacOS/Orange"

setup:
	@[ -f config.json ] || { cp config.example.json config.json; echo "生成了 config.json"; }
	@mkdir -p "$(WORKDIR)/shared/memory"
	@[ -f "$(WORKDIR)/AGENTS.md" ] || { cp workspace/AGENTS.md "$(WORKDIR)/AGENTS.md"; echo "生成了 $(WORKDIR)/AGENTS.md"; }
	@[ -e "$(WORKDIR)/CLAUDE.md" ] || ln -s AGENTS.md "$(WORKDIR)/CLAUDE.md"

open:
	open "$(APP)"

clean:
	rm -f "$(APP)/Contents/MacOS/Orange"
