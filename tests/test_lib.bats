#!/usr/bin/env bats
# tests for lib/common/time/firewall

@test "lib/common.sh loads" {
  run bash -c 'source lib/common.sh; type info >/dev/null && echo ok'
  [ "$output" = "ok" ]
}

@test "lib/time.sh ensure_time_sync dry-run" {
  # lib/time.sh 依赖 lib/common.sh 的 info()/run()，必须先 source 前者（同 vpnmax 用例）
  run bash -c 'source lib/common.sh; source lib/time.sh; DRY_RUN=true ensure_time_sync'
  [[ "$output" == *"dry-run"* ]]
}

@test "lib/firewall.sh constants exist" {
  run bash -c 'source lib/firewall.sh; echo $HOP_HY_RANGE'
  [ "$output" = "40000:42000" ]
}

@test "lib/verify/time.sh loads" {
  run bash -c 'source lib/verify/time.sh; type verify_time >/dev/null && echo ok'
  [ "$output" = "ok" ]
}

@test "subscription token-port whitelist fail-closed" {
  run bash -c 'source lib/common.sh; source lib/subscription.sh; vpnplus_valid_subtoken "Abc12345" && vpnplus_valid_subport 22345 && ! vpnplus_valid_subtoken "a;b\$(x)" && ! vpnplus_valid_subtoken short && ! vpnplus_valid_subport 80 && ! vpnplus_valid_subport "12;rm"'
  [ "$status" -eq 0 ]
  run bash -c 'source lib/common.sh; source lib/subscription.sh; t=$(vpnplus_new_subtoken); vpnplus_valid_subtoken "$t"'
  [ "$status" -eq 0 ]
  run bash -c 'source lib/common.sh; source lib/subscription.sh; type ensure_sub_perms >/dev/null && echo ok'
  [ "$output" = "ok" ]
  # 回环绑定：crontab 与 nohup 均只听 127.0.0.1，不得出现无 IP 的 -p "$port" 与 cat 拼接
  grep -q 'busybox httpd -f -p "127.0.0.1:${port}"' lib/subscription.sh
  grep -q 'busybox httpd -f -p 127.0.0.1:${port}' lib/subscription.sh
  run bash -c '! grep -q "cat /etc/s-box/subport.log" lib/subscription.sh'
  [ "$status" -eq 0 ]
}

@test "argo-extra whitelist array-passing keepalive" {
  run bash -c 'source lib/common.sh; source lib/argo.sh; d=$(mktemp -d); printf "%s\n" "--edge-ip-version 4" "--region en" >"$d/extra"; out=$(vpnplus_argo_extra_args "$d/extra"); test "$out" = " --edge-ip-version 4 --region en"; printf "%s\n" "--edge-ip-version 4; rm -rf /" >"$d/evil"; out=$(vpnplus_argo_extra_args "$d/evil" 2>/dev/null); ! echo "$out" | grep -q ";"; rm -rf "$d"'
  [ "$status" -eq 0 ]
  # 数组传参三件套：want_arr 声明 + read -ra + 引号展开
  grep -q 'want_arr=()' lib/argo.sh
  grep -q 'read -ra want_arr' lib/argo.sh
  grep -q '"${want_arr\[@\]}"' lib/argo.sh
  # keepalive 内无引号 $(cat argo-extra.conf) 拼接已消除，G4 去重与 L3 五文件同步在位
  run bash -c '! grep -q "\$(cat /etc/s-box/argo-extra.conf" lib/argo.sh'
  [ "$status" -eq 0 ]
  grep -q '只保留最新' lib/argo.sh
  grep -q 'SUB_ARGO_FILES=' lib/argo.sh
  grep -q 'clmi.yaml' lib/argo.sh
  run bash -c 'source lib/common.sh; source lib/argo.sh; type ensure_argo_extra_applied >/dev/null && echo ok'
  [ "$output" = "ok" ]
}

@test "entry --help no stray command R6" {
  for s in bootstrap.sh deploy_optimize.sh deploy_singbox.sh cleanup.sh; do
    run timeout 20 bash "$s" --help
    [ "$status" -eq 0 ]
    [[ "$output" != *"No such file or directory"* ]]
    [[ "$output" != *"command not found"* ]]
  done
}

@test "integrity gate passes and GBK safe" {
  run python3 tools/check-lib-integrity.py
  [ "$status" -eq 0 ]
  d=$(mktemp -d)
  printf '#!/bin/bash\n# \xd6\xd0\xce\xc4\xd7\xa2\xca\xcd\nreadonly GBK_T=1\n' >"$d/gbk.sh"
  run python3 -c 'import sys; from pathlib import Path; t = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace"); assert "GBK_T" in t; print("gbk-ok")' "$d/gbk.sh"
  [ "$output" = "gbk-ok" ]
  run bash -c 'grep -c "errors=\"replace\"" tools/check-lib-integrity.py'
  [ "$output" -ge 3 ]
  ! grep -q 'read_text(encoding="utf-8")' tools/check-lib-integrity.py
  rm -rf "$d"
}
