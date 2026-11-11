#!/bin/sh
# 一次性初始化，每次创建容器都会重跑（必须在 gitea 启动前完成，gitea 启动时才按 DB
# 注册 OAuth2 provider；CLI 是独立进程，对运行中的 gitea 改认证源不生效，见
# go-gitea/gitea#35611）：把云吞的 OIDC 认证源写进 Gitea 数据库
#（源名 wonton，回调 /user/oauth2/wonton/callback）。
# 保留数据重装时客户端密钥已换，必须重写，不能"已存在就跳过"。
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
echo "init-db: OIDC 认证源已写入，等 gitea 启动后生效"
