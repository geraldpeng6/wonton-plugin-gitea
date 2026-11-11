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

wait_init() { # 升级=卸载(留数据)+新装：Gitea 数据卷里留着旧认证源（旧密钥），init 要等 gitea
	# healthy 后才重写它。探针见"源已存在"就走链会撞上旧密钥，所以等 init 容器退出再走。
	local inic i
	inic="$(docker ps -a --format '{{.Names}}' | grep -E -- "-gitea--init$" | head -1)"
	[[ -n "$inic" ]] || return 0
	for ((i = 0; i < 45; i++)); do
		[[ "$(docker inspect -f '{{.State.Status}}' "$inic" 2>/dev/null)" == exited ]] && return 0
		sleep 2
	done
	echo "init 容器 90 秒没跑完，不等了"
}

gitea_session() { # <jar 文件>：jar 已登录就直接返回页面；否则核心登录 + 入口页 SSO 链。
	# 链路要求 Accept: text/html：网关对无会话的网页请求按该头回 302 跳 SSO，否则回 401 JSON。
	# 对已登录的 jar 重走 OAuth 链会被 Gitea 重开授权流程打断，所以先查会话。
	local page base="${E2E_BASE:-${SMOKE_BASE:-}}" token="${E2E_TOKEN:-${SMOKE_TOKEN:-}}"
	page="$(curl -sS --noproxy '*' -L -b "$1" -c "$1" -H 'Accept: text/html' "$SMOKE_WEB_URL/")" ||
		{ echo "应用首页拉不到"; return 1; }
	grep -q 'href="/-/admin"' <<<"$page" && { printf '%s' "$page"; return 0; }
	[[ -n "$base" && -n "$token" ]] || { echo "没有核心地址或主人令牌"; return 1; }
	wait_init
	curl -sS --noproxy '*' --fail-with-body -o /dev/null -c "$1" --data-urlencode "token=$token" \
		"$base/_wonton/login" || { echo "用户令牌登录不了核心"; return 1; }
	curl -sS --noproxy '*' --fail-with-body -o /dev/null -L -b "$1" -c "$1" -H 'Accept: text/html' \
		"$SMOKE_WEB_URL/user/oauth2/wonton" || { echo "走不通插件网页的登录跳转"; return 1; }
	page="$(curl -sS --noproxy '*' -L -b "$1" -c "$1" -H 'Accept: text/html' "$SMOKE_WEB_URL/")" ||
		{ echo "落点页拉不到"; return 1; }
	grep -q 'href="/-/admin"' <<<"$page" ||
		{ echo "OIDC 链没落回登录后的仪表盘（title：$(grep -o '<title>[^<]*' <<<"$page" | head -1)）"; return 1; }
	printf '%s' "$page"
}

identity_check() { # OIDC 链落回仪表盘后，断言是主人且是管理员
	local page
	page="$(gitea_session "$SMOKE_JAR")" || { echo "$page"; return 1; }
	grep -q "href=\"/$SMOKE_OWNER\"" <<<"$page" || { echo "页面没有主人 $SMOKE_OWNER 的资料链接：$(head -c 200 <<<"$page")"; return 1; }
	grep -q 'href="/-/admin"' <<<"$page" || { echo "主人不是管理员（没有 /-/admin 入口）：$(head -c 200 <<<"$page")"; return 1; }
}

data_write() { # 建一个固定名字的私有仓库（冒烟每次起新实例，不存在上次残留；重跑幂等）
	local page uid out status
	# 先存下来再匹配：管道里 grep -q 一命中就退出，curl 写剩下的内容报 23，pipefail 下整条算失败。
	page="$(gitea_session "$SMOKE_JAR")" || { echo "$page"; return 1; }
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
	page="$(gitea_session "$SMOKE_JAR")" || { echo "$page"; return 1; }
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

_mp_wait() { # <jq 参数…> [轮数=20]：轮询 Mailpit 信箱直到过滤命中。参数原样交给 jq（--arg 键 值、过滤串）；
  # 最后一个参数是纯数字时取作轮数。
  local -a args=()
  local n=20 a i out
  while (($#)); do
    a="$1"; shift
    if (($# == 0)) && [[ "$a" =~ ^[0-9]+$ ]]; then n="$a"; else args+=("$a"); fi
  done
  ((${#args[@]})) || { echo "mp_wait 没给 jq 过滤"; return 1; }
  for ((i = 0; i < n; i++)); do
    out="$(_mp_api "/api/v1/messages?limit=100")" || { sleep 3; continue; }
    jq -e "${args[@]}" <<<"$out" >/dev/null 2>&1 && return 0
    sleep 3
  done
  return 1
}

# 核心把信投进主人的私聊后马上从内部邮箱删掉（投完才删），等“信出现在 Mailpit”有竞态：
# 直接断言投递的结果——以主人身份读主人的 Wonton 私聊（通知房间），找这个插件发的信。

_mx_curl() { # <路径> [curl 参数…]：在核心容器的网络栈里调 Tuwunel 的 Matrix 客户端接口（宿主够不着）
  local path="$1"; shift
  docker run --rm --network "container:wonton-${SMOKE_INSTANCE:?}--core" curlimages/curl:8.23.0 \
    -sS --noproxy '*' --max-time 30 --fail-with-body "$@" "http://tuwunel.wonton.internal:8008$path"
}

_mx_room_mail() { # <插件 id>：以主人身份读主人的 Wonton 私聊，输出这个插件发进来的信（结构化事件数组）
  local core="wonton-${SMOKE_INSTANCE:?}--core" admin server room owner tok enc
  admin="$(docker exec "$core" sh -c 'cat "$WONTON_DATA_DIR/core/matrix-admin-token"')" ||
    { echo "拿不到核心的 Matrix 管理令牌"; return 1; }
  server="$(docker exec "$core" sh -c 'cat "$WONTON_MATRIX_SERVER_NAME_FILE" 2>/dev/null || printf %s "${WONTON_MATRIX_SERVER_NAME:-}"')"
  [[ -n "$server" ]] || { server="${SMOKE_BASE#*://}"; server="${server%%:*}"; }
  room="$(docker exec "$core" sh -c 'cat "$WONTON_DATA_DIR/core/matrix-notice-room" 2>/dev/null')" ||
    { echo "主人的通知房间还没建（还没投过信？）"; return 1; }
  enc="$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$room")"
  owner="@${SMOKE_OWNER:-owner}:$server"
  tok="$(_mx_curl "/_synapse/admin/v1/users/$owner/login" \
    -H "Authorization: Bearer $admin" -H 'Content-Type: application/json' -d '{}' | jq -er '.access_token // empty')" ||
    { echo "换不出主人的 Matrix 会话（impersonate 失败）"; return 1; }
  _mx_curl "/_matrix/client/v3/rooms/$enc/messages?dir=b&limit=30" -H "Authorization: Bearer $tok" |
    jq -c --arg id "$1" '[.chunk[] | select(.content["app.wonton.plugin_mail"].plugin_id == $id)]'
}

_mx_wait_mail() { # <插件 id> [轮数=30]：轮询主人的私聊，等这封信出现在房间里（每轮 2 秒）
  local id="$1" n="${2:-30}" i chunk
  for ((i = 0; i < n; i++)); do
    chunk="$(_mx_room_mail "$id")" || { sleep 2; continue; }
    [[ "$chunk" != "[]" ]] && { printf '%s' "$chunk"; return 0; }
    sleep 2
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
  local appc rc to page
  appc="$(docker ps --format '{{.Names}}' | grep -E -- "-gitea--gitea$|gitea-gitea-1$" | head -1)"
  [[ -n "$appc" ]] || { echo "找不到 Gitea 应用容器"; return 1; }
  rc="$(docker exec "$appc" printenv GITEA__mailer__SMTP_ADDR)$(docker exec "$appc" printenv GITEA__mailer__SMTP_PORT)" ||
    { echo "应用容器没有 GITEA__mailer__*"; return 1; }
  [[ "$rc" == "smtp.wonton.internal25" ]] ||
    { echo "发信环境变量不对：GITEA__mailer__SMTP_ADDR/PORT=$rc"; return 1; }
  echo "发信环境变量已注入：$rc"

  to="$(_owner_email)" || { echo "$to"; return 1; }
  page="$(gitea_session "$SMOKE_JAR")" || { echo "拿不到应用会话：$page"; return 1; }

  # 真实发信测试：管理面板建号表单（session+CSRF），send_notify 让 Gitea 真发"账号已创建"邮件，
  # 收件人填主人的内部邮箱。找回密码页对已登录用户重定向（SSO 链必然登录应用），用不了。
  form="$(curl -sS --noproxy '*' -b "$SMOKE_JAR" -H 'Accept: text/html' "$SMOKE_WEB_URL/-/admin/users/new")" ||
    { echo "拿不到管理建号页"; return 1; }
  grep -q 'id="user_name"' <<<"$form" ||
    { echo "管理建号页不对（title：$(grep -o '<title>[^<]*' <<<"$form" | head -1)）"; return 1; }
  action="$(grep -o '<form[^>]*action="[^"]*"' <<<"$form" | grep -o 'action="[^"]*"' | head -1 | sed -E 's/action="([^"]*)".*/\1/')"
  [[ "$action" == /* ]] || action="/-/admin/users/new"
  csrf="$(grep -o 'name="_csrf" value="[^"]*"' <<<"$form" | head -1 | sed -E 's/.*value="([^"]*)".*/\1/')"
  if [[ -z "$csrf" ]]; then
    csrf="$(grep -o '<input[^>]*name="_csrf"[^>]*>' <<<"$form" | head -1 | sed -E 's/.*value="([^"]*)".*/\1/')"
  fi
  if [[ -z "$csrf" ]]; then
    echo "管理建号页没有 _csrf：title：$(grep -o '<title>[^<]*' <<<"$form" | head -1)；form 数：$(grep -c '<form' <<<"$form")；csrf 痕迹：$(grep -o 'csrf[^>]\{0,60\}' <<<"$form" | head -2 | tr '\n' '|')"
    return 1
  fi
  local u st
  u="wonton-mail-$(date +%s)"
  st="$(curl -sS --noproxy '*' -b "$SMOKE_JAR" -o /dev/null -w '%{http_code}' \
    --data-urlencode "_csrf=$csrf" \
    --data-urlencode "user_name=$u" \
    --data-urlencode "email=$to" \
    --data-urlencode "password=Wonton-${u}aA1" \
    --data-urlencode "send_notify=on" \
    "$SMOKE_WEB_URL$action")" || { echo "POST $action 失败"; return 1; }
  [[ "$st" == 200* || "$st" == 302* || "$st" == 303* ]] ||
    { echo "建测试用户没成功（HTTP $st）"; return 1; }
  # 临时用户随冒烟实例销毁，不做清理（实例是一次性的）

  if ! _mx_wait_mail io.gitea.gitea; then
    { echo "60 秒内没在主人的 Wonton 私聊看到 Gitea 的建号邮件（收件人 $to）"; return 1; }
  fi
  echo "Gitea 的建号邮件已投进 $to 的 Wonton 私聊"
}

