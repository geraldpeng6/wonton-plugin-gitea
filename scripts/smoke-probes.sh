# shellcheck shell=bash
# scripts/smoke.sh 的一项一项探测，跟着插件走。没写的项会 FAIL 并给出写法，不会默认放行。
#
# 页面：web_assert 从标准输入读页面，命中的确是应用的真实页面时返回 0。
# 身份：identity_check 走完 OIDC 链后断言 Gitea 认出主人，而且是管理员（dashboard 只有管理员
#       看得到 /-/admin 入口）。dweb / web_get 是带用户会话的请求助手。
# 工具：Gitea 没有声明 MCP，不写 mcp_check。
# 数据：data_write 用随机名字建一个私有仓库，data_check 升级/重装后读回核对。
#       两个钩子都先重走一遍 OIDC（会话可能过期，钩子执行顺序不依赖 harness）。

gitea_session() { # <jar 文件>：dweb 走完 OIDC 链，Gitea 会话落在 jar 里；输出落点页面
	dweb /user/oauth2/wonton -L -b "$1" -c "$1"
}

web_assert() { grep -qi 'gitea'; }

identity_check() { # OIDC 链落回仪表盘后，断言是主人且是管理员
	local page
	page="$(gitea_session "$SMOKE_JAR")" || { echo "OIDC 链失败：$page"; return 1; }
	grep -q "href=\"/$SMOKE_OWNER\"" <<<"$page" || { echo "页面没有主人 $SMOKE_OWNER 的资料链接：$(head -c 200 <<<"$page")"; return 1; }
	grep -q 'href="/-/admin"' <<<"$page" || { echo "主人不是管理员（没有 /-/admin 入口）：$(head -c 200 <<<"$page")"; return 1; }
}

data_write() { # 用随机名字建一个私有仓库
	local marker name uid out
	marker="$(head -c12 /dev/urandom | od -An -tx1 | tr -d ' \n')"
	printf '%s' "$marker" >"$SMOKE_STATE/gitea-data-marker"
	name="wonton-smoke-$marker"
	gitea_session "$SMOKE_JAR" | grep -qi gitea || { echo "OIDC 链没有落回 Gitea 页面"; return 1; }
	uid="$(curl -sS --noproxy '*' --fail-with-body -b "$SMOKE_JAR" "$SMOKE_WEB_URL/repo/create" |
		grep -o 'name="uid" value="[0-9]*"' | grep -o '[0-9]*' | head -1)"
	[[ -n "$uid" ]] || { echo "建仓库页取不到 uid"; return 1; }
	out="$(curl -sS --noproxy '*' -b "$SMOKE_JAR" -o /dev/null -w '%{http_code} %{redirect_url}' \
		--data-urlencode "uid=$uid" --data-urlencode "repo_name=$name" --data-urlencode 'private=true' \
		"$SMOKE_WEB_URL/repo/create")"
	case "$out" in
	302* | 303*) : ;;
	*) echo "建仓库失败：$out" ;;
	esac
}

data_check() { # 升级/重装后重新走 OIDC，核对仓库还在
	local marker status
	marker="$(cat "$SMOKE_STATE/gitea-data-marker" 2>/dev/null)"
	[[ -n "$marker" ]] || { echo "没有 data-write 留下的标记"; return 1; }
	gitea_session "$SMOKE_JAR" | grep -qi gitea || { echo "OIDC 链没有落回 Gitea 页面"; return 1; }
	status="$(curl -sS --noproxy '*' -b "$SMOKE_JAR" -o /dev/null -w '%{http_code}' \
		"$SMOKE_WEB_URL/$SMOKE_OWNER/wonton-smoke-$marker")"
	[[ "$status" == 200 ]] || { echo "仓库不见了（HTTP $status）"; return 1; }
}
