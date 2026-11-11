# shellcheck shell=bash
# scripts/smoke.sh 的一项一项探测，跟着插件走。没写的项会 FAIL 并给出写法，不会默认放行。
#
# 页面：web_assert 从标准输入读页面，命中的确是应用的真实页面时返回 0。
# 身份：identity_check 走完 OIDC 链后断言 Gitea 认出主人，而且是管理员（dashboard 只有管理员
#       看得到 /-/admin 入口）。dweb / web_get 是带用户会话的请求助手。
# 工具：Gitea 没有声明 MCP，不写 mcp_check。
# 数据：data_write 建一个固定名字的私有仓库（冒烟每次起新实例，重跑幂等），
#       data_check 升级/重装后读回核对。两个钩子都先重走一遍 OIDC（会话可能过期，
#       钩子执行顺序不依赖 harness）。

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

data_write() { # 建一个固定名字的私有仓库（冒烟每次起新实例，不存在上次残留；重跑幂等）
	local page uid out status
	# 先存下来再匹配：管道里 grep -q 一命中就退出，curl 写剩下的内容报 23，pipefail 下整条算失败。
	page="$(gitea_session "$SMOKE_JAR")" || { echo "OIDC 链走不通"; return 1; }
	grep -qi gitea <<<"$page" || { echo "OIDC 链没有落回 Gitea 页面"; return 1; }
	status="$(curl -sS --noproxy '*' -b "$SMOKE_JAR" -o /dev/null -w '%{http_code}' \
		"$SMOKE_WEB_URL/$SMOKE_OWNER/wonton-smoke")"
	[[ "$status" == 200 ]] && return 0
	page="$(curl -sS --noproxy '*' --fail-with-body -b "$SMOKE_JAR" "$SMOKE_WEB_URL/repo/create")" ||
		{ echo "建仓库页失败"; return 1; }
	uid="$(grep -o 'name="uid" value="[0-9]*"' <<<"$page" | grep -o '[0-9]*' | head -1)"
	[[ -n "$uid" ]] || { echo "建仓库页取不到 uid"; return 1; }
	out="$(curl -sS --noproxy '*' -b "$SMOKE_JAR" -o /dev/null -w '%{http_code} %{redirect_url}' \
		--data-urlencode "uid=$uid" --data-urlencode 'repo_name=wonton-smoke' --data-urlencode 'private=true' \
		"$SMOKE_WEB_URL/repo/create")"
	case "$out" in
	302* | 303*) : ;;
	*) echo "建仓库失败：$out" ;;
	esac
}

data_check() { # 升级/重装后重新走 OIDC，核对仓库还在
	local page status
	# 先存下来再匹配：管道里 grep -q 一命中就退出，curl 写剩下的内容报 23，pipefail 下整条算失败。
	page="$(gitea_session "$SMOKE_JAR")" || { echo "OIDC 链走不通"; return 1; }
	grep -qi gitea <<<"$page" || { echo "OIDC 链没有落回 Gitea 页面"; return 1; }
	status="$(curl -sS --noproxy '*' -b "$SMOKE_JAR" -o /dev/null -w '%{http_code}' \
		"$SMOKE_WEB_URL/$SMOKE_OWNER/wonton-smoke")"
	[[ "$status" == 200 ]] || { echo "仓库不见了（HTTP $status）"; return 1; }
}

# ---------- 内部邮箱（notify）的端到端检查 ----------

_mp_api() { # <路径>：调 Mailpit 的 HTTP API（basic core:<api-password>）。Mailpit 只挂在插件网络，
  # 宿主够不着；照核心自己 smoke-mailbox 的做法，在核心容器的网络栈里起一次性 curl 访问它。
  local core pw dd out
  core="wonton-${SMOKE_INSTANCE:?}--core"
  docker inspect "$core" >/dev/null 2>&1 || { echo "找不到核心容器 $core"; return 1; }
  if declare -F read_env >/dev/null; then dd="$(read_env WONTON_DATA_DIR)"
  elif declare -F probes_setting >/dev/null; then dd="$(probes_setting WONTON_DATA_DIR)"
  else echo "读不到 WONTON_DATA_DIR（read_env / probes_setting 都没有）"; return 1; fi
  pw="$(docker exec "$core" cat "$dd/core/mailpit/api-password" 2>/dev/null)"
  [[ -n "$pw" ]] || { echo "读不到 Mailpit API 密码（核心数据目录 core/mailpit/api-password）"; return 1; }
  out="$(docker run --rm --network "container:$core" curlimages/curl:8.23.0 \
    -s -u "core:$pw" "http://mailpit.wonton.internal:8025$1" 2>&1)"
  if [[ "$out" == "{"* ]]; then printf '%s' "$out"; return 0; fi
  echo "Mailpit 没给出 JSON：$(head -c 200 <<<"$out")"
  return 1
}

_mp_wait() { # <jq 过滤> [轮数=20]：轮询 Mailpit 信箱直到过滤命中
  local filt="$1" n="${2:-20}" i out
  for ((i = 0; i < n; i++)); do
    out="$(_mp_api "/api/v1/messages?limit=100")" || { sleep 3; continue; }
    jq -e "$filt" <<<"$out" >/dev/null 2>&1 && return 0
    sleep 3
  done
  return 1
}

_owner_email() { # 主人资料里的内部邮箱（收件人用它，不猜域名）
  local base token me
  base="${E2E_BASE:-${SMOKE_BASE:-}}"; token="${E2E_TOKEN:-${SMOKE_TOKEN:-}}"
  [[ -n "$base" && -n "$token" ]] || { echo "没有核心地址或主人令牌"; return 1; }
  me="$(curl -sS --noproxy '*' --fail-with-body -H "Authorization: Bearer $token" "$base/_wonton/api/me")" ||
    { echo "读不到主人资料（/_wonton/api/me）"; return 1; }
  jq -er '.email // empty' <<<"$me" || { echo "主人资料里没有邮箱：$me"; return 1; }
}

extra_check() { # 内部邮箱端到端：SMTP 配置注入、真实找回密码信进 Mailpit、核心投进主人私聊后删掉
  local appc rc to page csrf
  appc="$(docker ps --format '{{.Names}}' | grep -E -- "-gitea--gitea$|gitea-gitea-1$" | head -1)"
  [[ -n "$appc" ]] || { echo "找不到 Gitea 应用容器"; return 1; }
  rc="$(docker exec "$appc" printenv GITEA__mailer__SMTP_ADDR)$(docker exec "$appc" printenv GITEA__mailer__SMTP_PORT)" ||
    { echo "应用容器没有 GITEA__mailer__*"; return 1; }
  [[ "$rc" == "smtp.wonton.internal25" ]] ||
    { echo "发信环境变量不对：GITEA__mailer__SMTP_ADDR/PORT=$rc"; return 1; }
  echo "发信环境变量已注入：$rc"

  to="$(_owner_email)" || { echo "$to"; return 1; }
  page="$(gitea_session "$SMOKE_JAR")" || { echo "OIDC 链走不通"; return 1; }

  # 真实找回密码信：POST /user/forgot_password（表单的 _csrf 与 Cookie 同值）
  page="$(curl -sS --noproxy '*' -b "$SMOKE_JAR" -c "$SMOKE_JAR" "$SMOKE_WEB_URL/user/forgot_password")" ||
    { echo "拿不到找回密码页"; return 1; }
  csrf="$(grep -o 'name="_csrf" value="[^"]*"' <<<"$page" | head -1 | sed -E 's/.*value="([^"]*)".*/\1/')"
  [[ -n "$csrf" ]] || { echo "找回密码页没有 _csrf"; return 1; }
  rc="$(curl -sS --noproxy '*' -b "$SMOKE_JAR" -o /dev/null -w '%{http_code}' \
    --data-urlencode "_csrf=$csrf" --data-urlencode "email=$to" \
    "$SMOKE_WEB_URL/user/forgot_password")" || { echo "POST /user/forgot_password 失败"; return 1; }
  [[ "$rc" == 200* || "$rc" == 302* || "$rc" == 303* ]] ||
    { echo "找回密码请求没成功（HTTP $rc）"; return 1; }
  _mp_wait --arg to "$to" '.messages | any(.To[].Address == $to)' ||
    { echo "60 秒内没在内部邮箱看到收件人 $to 的找回密码信"; return 1; }
  echo "找回密码信已进内部邮箱（收件人 $to）"
  _mp_wait --arg to "$to" '(.messages | map(select(.To[].Address == $to)) | length) == 0' ||
    { echo "信一直留在 Mailpit：核心没把它投进收件人的 Wonton 私聊（投完才会删）"; return 1; }
  echo "核心已把找回密码信投进 $to 的 Wonton 私聊"
}
