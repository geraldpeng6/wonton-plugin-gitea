#!/bin/sh
# 一次性初始化，每次创建容器都会重跑：
# 1. 把云吞的 OIDC 认证源登记进 Gitea 数据库（源名 wonton，回调 /user/oauth2/wonton/callback）。
#    保留数据重装时客户端密钥已换，必须重写，不能"已存在就跳过"。
#    groups 声明里是云吞用户组（["owner"]），owner 组映射成 Gitea 管理员。
# 2. 把主人账号的邮箱对齐成云吞注入的内部邮箱。OIDC 只在自动注册建号时取邮箱声明，命中已有账号后
#    不再更新（登录只同步激活、管理员和组），核心换成内部邮箱之前装的实例，账号邮箱还是当时的真实
#    地址，找回密码和通知会寄到外面被核心拒收。还没有账号（主人没登录过）或邮箱已经是内部地址时
#    什么都不做：之后 OIDC 建号自带内部邮箱。
set -eu

discovery="${WONTON_OIDC_ISSUER}/.well-known/openid-configuration"
# gitea admin auth list --vertical-bars 的行是 "ID\t|Name\t|Type\t|Enabled"。
# 认证源存在就删了重加：update-oauth 不更新客户端密钥（升级/重装换了密钥后，旧源留着旧密钥，
# 兑换会 invalid_client），delete+add 才保证密钥、方式和作用域都按这次注入的来。
id="$(gitea admin auth list --vertical-bars 2>/dev/null |
	awk -F'|' 'NR>1 {gsub(/[\t ]/,"",$1); gsub(/[\t ]/,"",$2); if ($2 == "wonton") print $1}')"
if [ -n "$id" ]; then
	gitea admin auth delete --id "$id"
fi
gitea admin auth add-oauth \
	--name wonton --provider openidConnect \
	--key "$WONTON_OIDC_CLIENT_ID" --secret "$WONTON_OIDC_CLIENT_SECRET" \
	--auto-discover-url "$discovery" \
	--scopes openid --scopes profile --scopes email --scopes groups \
	--group-claim-name groups --admin-group owner

# gitea admin user list 的行是 "ID Username Email IsActive IsAdmin 2FA Type"，用户名和邮箱没有空白。
row="$(gitea admin user list 2>/dev/null | awk -v u="$WONTON_OWNER_NAME" '$2 == u && $NF == "User"')"
if [ -z "$row" ]; then
	echo "init: 主人账号还没建（首次登录自动注册时自带内部邮箱），跳过邮箱对齐"
	exit 0
fi
email="$(printf '%s\n' "$row" | awk '{print $3}')"
if [ "$email" = "$WONTON_OWNER_EMAIL" ]; then
	echo "init: 主人账号的邮箱已是内部地址，不用对齐"
	exit 0
fi

# 改邮箱走管理员接口：先给主人账号发一个用完即删的令牌（write:admin 调接口，write:user 删令牌；
# 令牌管理接口只认 Basic 认证，所以用"用户名+令牌当密码"删自己）。令牌改名用随机后缀，
# 上一次运行没删干净也不挡这次。
tokname="wonton-mail-init-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
tok="$(gitea admin user generate-access-token -u "$WONTON_OWNER_NAME" -t "$tokname" \
	--scopes write:admin,write:user --raw 2>/dev/null | tail -1)"
[ -n "$tok" ] || { echo "init: 给主人账号发访问令牌失败，没法对齐邮箱" >&2; exit 1; }

code="$(curl -sS -o /tmp/mail-init-resp.json -w '%{http_code}' -X PATCH \
	"http://gitea:3000/api/v1/admin/users/$WONTON_OWNER_NAME" \
	--header "Authorization: token $tok" --header 'Content-Type: application/json' \
	--data "{\"email\": \"$WONTON_OWNER_EMAIL\"}")" || code=0
del="$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE \
	"http://gitea:3000/api/v1/users/$WONTON_OWNER_NAME/tokens/$tokname" \
	--user "$WONTON_OWNER_NAME:$tok")" || del=0
[ "$del" = 204 ] || echo "init: 令牌 $tokname 删除失败（HTTP $del），留在 Gitea 里要手工删" >&2
if [ "$code" != 200 ]; then
	echo "init: 对齐主人账号邮箱失败（HTTP $code）：$(cat /tmp/mail-init-resp.json)" >&2
	exit 1
fi
echo "init: 主人账号邮箱已对齐成 $WONTON_OWNER_EMAIL"
