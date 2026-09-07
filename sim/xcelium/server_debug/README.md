# 서버 실행 로그 전달 위치

서버에서 발생한 commit/trap 문제를 전달할 때
[`commit_trap_log.txt`](./commit_trap_log.txt)를 GitHub에서 직접 편집하거나,
로컬에서 내용을 붙여 넣은 뒤 커밋·푸시한다.

로그는 자르거나 정렬하지 말고 원문 순서 그대로 넣는다. 특히 ELF loader 메시지,
trap 직전 commit, `cause`, `tval`, timeout 메시지가 함께 있어야 원인을 구분할 수 있다.
