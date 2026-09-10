# VMware snapshot chain 읽기 수정 (#971 검증 차단 / #1003)

DR full-seed/full-reseed와 CBT patch 모두 nbdkit VDDK `single-link=false`로 전체 부모 체인을 연다. capture별 VMware snapshot/VM/device-key 재해석과 read-only, CBT extent 선택, 대상 writer/authority 계약은 유지한다. 레거시 v2k 및 다른 DR 경로는 변경하지 않는다.

## 실측 근거
2026-09-10 32.2, nbdkit1.38.5, 기존 외부 snapshot62747의 test1-000004.vmdk를 읽기 전용으로 비교. 같은 snapshot/VM/path/TLS 조건에서 single-link=true 첫1MiB는 전부0, GPT 없음; false는 nonzero188bytes, EFI PART, SHA e67cf75fa57b9c5b05943804e8a0420729d92573089abf671156ea5b10da3f81. 블록 map도 true present=false/data=false, false present=true/data=true.

full-reseed Run441은100GiB 전송 성공이나 Test442 실패, clone 첫1MiB가0. 이전 증분Test440은 XFS zeroed log/LSN 불일치. 원본 변경 여부 추정이 아니라 같은 immutable snapshot의 옵션 비교로 데이터 누락을 확인했다.

공식 옵션 계약: https://libguestfs.org/nbdkit-vddk-plugin.1.html

## 검증 계획
기존 branch release 전체 lifecycle/terminal/tombstone gate를 GitHub Actions로 수행한다. RPM 설치 후 실제 full-reseed, VMware 대상 OS/virtio 부팅(QGA 양단 제외), RUNNING cleanup 복원 및 PAUSED 유지, source-vCenter 단절 테스트를 재검증한다. 실패경로 잔여 자원/HELD 복원은 별도 #1004이며 정상경로 PASS와 구분한다. 기존 외부 스냅샷은 보존한다.
