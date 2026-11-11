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

_mp_api() { # <路径>：调 Mailpit 的 HTTP API（basic core:<api-password>）。Mailpit 只挂在插件网络，
	# 宿主够不着；在核心容器的网络栈里起一次性 curl 访问它。数据目录从核心容器环境读，不依赖套件函数。
	local core pw dd out
	core="wonton-${SMOKE_INSTANCE:?}--core"
	docker inspect "$core" >/dev/null 2>&1 || { echo "找不到核心容器 $core"; return 1; }
	dd="$(docker exec "$core" printenv WONTON_DATA_DIR 2>/dev/null)"
	[[ -n "$dd" ]] || { echo "核心容器没有 WONTON_DATA_DIR"; return 1; }
	pw="$(docker exec "$core" cat "$dd/core/mailpit/api-password" 2>/dev/null)"
	[[ -n "$pw" ]] || { echo "读不到 Mailpit API 密码（核心数据目录 core/mailpit/api-password）"; return 1; }
	out="$(docker run --rm --network "container:$core" curlimages/curl:8.23.0 \
		-s -u "core:$pw" "http://mailpit.wonton.internal:8025$1" 2>&1)"
	if [[ "$out" == "{"* ]]; then printf '%s' "$out"; return 0; fi
	echo "Mailpit 没给出 JSON：$(head -c 200 <<<"$out")"
	return 1
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

  page="$(gitea_session "$SMOKE_JAR")" || { echo "拿不到应用会话：$page"; return 1; }

  # 真实通知管道：主人建公开仓库，测试用户（Basic 认证）在其中开 issue，Gitea 给主人（watch
  # 自己的仓库）发 issue 通知邮件，收件人是主人的内部邮箱。测试用户自己的地址是占位（不会被发信）。
  # 不能用建号邮件（send_notify）：它发给测试用户自己的地址，核心只放行 <用户名>@wonton.internal，
  # 会 550 拒收；而测试用户也不能占主人唯一的内部邮箱。
  to="$(docker exec -u 1000:1000 "$appc" gitea admin user list 2>/dev/null | awk -v o="$SMOKE_OWNER" '$2 == o {print $3}')" ||
    to=""
  [[ "$to" == *@wonton.internal ]] || { echo "主人在 Gitea 里的邮箱不是内部地址：${to:-空}（user list 取不到就用不了通知邮件）"; return 1; }

  local u pw st body repo
  repo="wonton-mail-smoke-$(date +%s)"
  u="wonton-mail-$(date +%s)"
  pw="Wonton-${u}aA1"
  form="$(curl -sS --noproxy '*' -b "$SMOKE_JAR" -H 'Accept: text/html' "$SMOKE_WEB_URL/-/admin/users/new")" ||
    { echo "拿不到管理建号页"; return 1; }
  grep -q 'id="user_name"' <<<"$form" ||
    { echo "管理建号页不对（title：$(grep -o '<title>[^<]*' <<<"$form" | head -1)）"; return 1; }
  # 页面有多个 form（搜索、登出、建号），取包含 id="user_name" 的那个的 action
  action="$(awk '/<form/{f=$0} /id="user_name"/{print f; exit}' <<<"$form" |
    grep -o 'action="[^"]*"' | head -1 | sed -E 's/action="([^"]*)".*/\1/')"
  [[ "$action" == /* ]] || { echo "建号 form 取不到 action，页面 form：$(grep -c '<form' <<<"$form") 个"; return 1; }
  body="$(curl -sS --noproxy '*' -b "$SMOKE_JAR" -w '\n%{http_code}' \
    -H "Origin: $SMOKE_WEB_URL" \
    --data-urlencode "user_name=$u" \
    --data-urlencode "login_type=0-0" \
    --data-urlencode "email=$u@example.org" \
    --data-urlencode "password=$pw" \
    "$SMOKE_WEB_URL$action")" || { echo "POST $action 失败"; return 1; }
  st="${body##*$'\n'}"
  if [[ "$st" != 200* && "$st" != 302* && "$st" != 303* ]]; then
    echo "建测试用户没成功（HTTP $st）"; return 1
  fi
  # 以用户列表为准确认建上了，别拿 200/302 当成功；失败时把表单页的错误带出来
  if ! docker exec -u 1000:1000 "$appc" gitea admin user list 2>/dev/null | awk -v u="$u" '$2 == u {found=1} END {exit !found}'; then
    echo "测试用户 $u 没建成（POST 回了 $st）：$(grep -oE 'flash-message[^<]*<[^>]*>[^<]{0,120}' <<<"$body" | head -2 | tr '\n' '|')；页面 title：$(grep -o '<title>[^<]*' <<<"${body%$'\n'*}" | head -1)"
    return 1
  fi
  # 临时用户和仓库随冒烟实例销毁，不做清理（实例是一次性的）

  # 主人建公开仓库（web 表单，同 data_write 的做法）
  page="$(curl -sS --noproxy '*' -b "$SMOKE_JAR" -H 'Accept: text/html' "$SMOKE_WEB_URL/repo/create")" ||
    { echo "拿不到建仓库页"; return 1; }
  local uid
  uid="$(grep -o 'name="uid" value="[0-9]*"' <<<"$page" | grep -o '[0-9]*' | head -1)"
  [[ -n "$uid" ]] || { echo "建仓库页取不到 uid"; return 1; }
  st="$(curl -sS --noproxy '*' -b "$SMOKE_JAR" -o /dev/null -w '%{http_code}' \
    -H "Origin: $SMOKE_WEB_URL" \
    --data-urlencode "uid=$uid" --data-urlencode "repo_name=$repo" --data-urlencode "private=false" \
    "$SMOKE_WEB_URL/repo/create")" || { echo "POST /repo/create 失败"; return 1; }
  [[ "$st" == 200* || "$st" == 302* || "$st" == 303* ]] || { echo "建仓库没成功（HTTP $st）"; return 1; }

  # 给测试用户发个 API 令牌（admin CLI），用它开 issue：Gitea 28 的 API 对 Basic 认证返回 401
  local tok
  tok="$(docker exec -u 1000:1000 "$appc" gitea admin user generate-access-token -u "$u" \
    -t "wonton-mail-token-$(date +%s)" --scopes write:repository --raw 2>/dev/null | tail -1)" ||
    { echo "给测试用户发令牌失败"; return 1; }
  [[ -n "$tok" ]] || { echo "测试用户令牌是空的"; return 1; }
  local issue
  issue="$(curl -sS --noproxy '*' -w '\n%{http_code}' \
    -H "Authorization: token $tok" -H 'Content-Type: application/json' \
    -d "{\"title\":\"wonton mail test $repo\"}" \
    "$SMOKE_WEB_URL/api/v1/repos/$SMOKE_OWNER/$repo/issues")" || { echo "开 issue 失败"; return 1; }
  st="${issue##*$'\n'}"
  if [[ "$st" != 201 ]]; then
    local repost
    repost="$(curl -sS --noproxy '*' -o /dev/null -w '%{http_code}' -H "Authorization: token $tok" \
      "$SMOKE_WEB_URL/api/v1/repos/$SMOKE_OWNER/$repo")"
    echo "开 issue 没成功（HTTP $st）：$(head -c 150 <<<"${issue%$'\n'*}")；仓库查证：$repost；令牌长度：${#tok}"
    return 1
  fi

  if ! _mx_wait_mail io.gitea.gitea; then
    local mp smtp queues
    mp="$(_mp_api '/api/v1/messages?limit=10' | jq -c '[.messages[] | {to: [.To[].Address], subject}]' 2>&1 | head -c 300)"
    smtp="$(docker exec -u 1000:1000 "$appc" sh -c \
      'addr="$(printenv GITEA__mailer__SMTP_ADDR)"; nc -zv -w 3 "$addr" 25 2>&1 || { getent hosts "$addr" || echo "DNS 解析不了 $addr"; }' 2>&1 | head -c 120)"
    users="$(docker exec -u 1000:1000 "$appc" gitea admin user list 2>/dev/null | grep -F "$u" | awk '{print "active="$4}')"
    queues="$(docker exec -u 1000:1000 "$appc" sh -c 'find /data/queues -type f 2>/dev/null | wc -l' 2>&1)"
    echo "60 秒内没在主人的 Wonton 私聊看到 Gitea 的 issue 通知邮件（收件人 $to）；内部邮箱：$mp；SMTP 连通：$smtp；测试用户：$users；队列文件：$queues"
    return 1
  fi
  echo "Gitea 的 issue 通知邮件已投进 $to 的 Wonton 私聊"
}

