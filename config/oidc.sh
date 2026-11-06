#!/bin/sh
# 把云吞的 OIDC 认证源登记进 Gitea 数据库（源名 wonton，回调 /user/oauth2/wonton/callback）。
# 每次创建容器都会重跑：保留数据重装时客户端密钥已换，必须重写，不能"已存在就跳过"。
# groups 声明里是云吞用户组（["owner"]），owner 组映射成 Gitea 管理员。
set -eu

discovery="${WONTON_OIDC_ISSUER}/.well-known/openid-configuration"
# gitea admin auth list --vertical-bars 的行是 "ID\t|Name\t|Type\t|Enabled"。
id="$(gitea admin auth list --vertical-bars 2>/dev/null |
	awk -F'|' 'NR>1 {gsub(/[\t ]/,"",$1); gsub(/[\t ]/,"",$2); if ($2 == "wonton") print $1}')"

if [ -n "$id" ]; then
	gitea admin auth update-oauth --id "$id" \
		--name wonton --provider openidConnect \
		--key "$WONTON_OIDC_CLIENT_ID" --secret "$WONTON_OIDC_CLIENT_SECRET" \
		--auto-discover-url "$discovery" \
		--scopes openid --scopes profile --scopes email --scopes groups \
		--group-claim-name groups --admin-group owner
else
	gitea admin auth add-oauth \
		--name wonton --provider openidConnect \
		--key "$WONTON_OIDC_CLIENT_ID" --secret "$WONTON_OIDC_CLIENT_SECRET" \
		--auto-discover-url "$discovery" \
		--scopes openid --scopes profile --scopes email --scopes groups \
		--group-claim-name groups --admin-group owner
fi
