<div align="center">

# Mini DRAM Controller

**요청 큐와 뱅크 병렬 스케줄러를 갖춘 SystemVerilog DRAM 메모리 컨트롤러**<br>
Spec → RTL → Verification → Performance / PPA

[![RTL](https://img.shields.io/badge/RTL-SystemVerilog-1f6feb)](rtl/)
[![Sim](https://img.shields.io/badge/Sim-Verilator%205.052-2ea44f)](Makefile)
[![Synth](https://img.shields.io/badge/Synth%20%2F%20STA-Yosys%200.52%20%C2%B7%20OpenSTA%203.1-8250df)](#ppa)
[![License](https://img.shields.io/badge/License-MIT-lightgrey)](LICENSE)

**[📄 포트폴리오 PDF (21쪽)](portfolio-deck/MiniDramController_Portfolio.pdf)** · [PPTX](portfolio-deck/MiniDramController_Portfolio.pptx) · [스펙 문서](docs/spec.md)

<a href="portfolio-deck/MiniDramController_Portfolio.pdf"><img src="portfolio-deck/cover.png" width="760" alt="포트폴리오 표지. 클릭하면 PDF가 열립니다"></a>

SK hynix HBM Digital Design (RTL Design) 지원 · 권용현

</div>

## 한눈에 보기

| 4-bank burst | 회귀 | 타이밍 규칙 | 코드 커버리지 |
| :---: | :---: | :---: | :---: |
| **17 cycles (2.06×)** | **5 / 5 PASS** | **7종 위반 0** | **Line 94.3%**<br>**Branch 91.9%** |
| 단일 FSM(v0)은 35 cycles | hit · miss · multi-bank<br>burst · back-pressure | tRCD · tRP · tRAS · tRC<br>tWR · tCL · tRFC | `mem_ctrl` 기준<br>Toggle 51.2% |

> [!NOTE]
> 커버리지와 PPA 수치, PDF의 파형은 commit `6049e5a`를 다시 실행해 측정했다. 그 뒤 `fa08330`(태그 wrap-around 수정)과 `7e2d4b5`(회귀 TB 보강)가 PDF 19쪽의 항목 A, C를 반영했다. 회귀, 타이밍 규칙, latency 수치는 현재 HEAD에서 다시 확인했다(Verilator 5.052).

## 개요

DRAM 접근 지연은 뱅크 상태에 따라 크게 달라진다. 같은 bank 0에서도 page hit RD는 6사이클, row conflict RD는 14사이클이다. 컨트롤러의 일은 명령 사이의 타이밍 제약을 사이클 단위로 지키면서, 한 뱅크가 기다리는 동안 다른 뱅크의 명령을 내보내 그 대기를 가리는 것이다.

이 저장소는 요청을 하나씩 처리하던 단일 FSM 컨트롤러(v0)를 **깊이 4 요청 큐 + 뱅크 엔진 ×4 + 사이클당 명령 1개 arbiter**(v1)로 바꾸고, 그 전환의 득실을 latency, throughput, 면적으로 수치화한 프로젝트다.

- **범위**: `host_if` → `mem_ctrl` → `dram_model`. 단일 클럭 동기 설계, 비동기 리셋
- **타이밍**: 자체 축소 모델(사이클 단위). JEDEC 값이 아니며, 구조와 규칙을 검증하기 위한 값이다
- **범위 밖**: 실제 PHY, multi-rank, ECC, 사인오프 PPA

## 주요 특징

| 기능 | 구현 |
| --- | --- |
| 요청 큐 | 깊이 4. 대상 뱅크가 IDLE인 엔트리 중 가장 오래된 tag부터 dispatch. 나이는 `q_tag − tag_retire`로 비교해 tag가 한 바퀴 돌아도 순서가 유지된다 |
| 뱅크 엔진 ×4 | 뱅크마다 `b_state`, `b_timer`. tRCD, tRP, tWR는 타이머가, tRAS, tRC는 `ras_rem`, `rc_rem`이 막는다 |
| 명령 arbiter | 사이클당 DRAM 명령 1개. 우선순위는 PRE > ACT > WR > RD, 같은 종류 안에서는 `rr_ptr`부터 round-robin |
| Page 정책 | Open-page. 같은 row면 ACT 없이 RD/WR, 다른 row가 열려 있으면 PRE → ACT, 닫혀 있으면 ACT |
| Refresh | Drain-then-REF. `tREFI`가 지나면 새 요청을 막고, 진행 중인 요청을 끝낸 뒤 REF |
| 응답 순서 | 16-entry 응답 버퍼에서 `tag_retire` 순서로 in-order 반환. 동시에 처리 중인 요청은 최대 15개 |
| Shadow open-row | 컨트롤러가 `bank_open`, `bank_row`를 직접 관리한다. 모델의 `page_hit`은 관측용이다 |

## 아키텍처

```mermaid
flowchart TB
  HOST(["Host · tb_mem_ctrl"])
  subgraph MC["mem_ctrl"]
    direction LR
    Q["<b>Request queue</b><br/>depth 4 · tag"] --> DSP["<b>Dispatch</b><br/>oldest tag → IDLE bank<br/>hit · closed · conflict"] --> ENG["<b>Bank engine ×4</b><br/>b_state · b_timer<br/>ras_rem · rc_rem"] --> ARB["<b>Arbiter</b><br/>PRE > ACT > WR > RD<br/>1 command / cycle"]
    REF["<b>Refresh</b><br/>tREFI → drain → REF"] --> ARB
    RSP["<b>Response buffer</b><br/>16 × 32b · in-order"]
  end
  DRAM[("dram_model<br/>4 bank · tCL · tRFC")]
  HOST <-->|"req_* / rsp_* · host_if"| MC
  MC <-->|"cmd · bank · row · col / data_valid · rdata"| DRAM
```

`mem_ctrl_top`이 `host_if`, `mem_ctrl`, `dram_model`을 연결한다. `host_if`는 지금 조합 pass-through이고, `dram_model`은 TB용 행동 모델이다.

### 뱅크 엔진 상태

dispatch 시점의 page 판정에 따라 세 경로로 나뉜다. 대기 상태는 타이머가 0이 되는 사이클에 상태만 바꾸고, 다음 명령은 그다음 사이클에 arbiter를 거쳐 나간다. 그래서 실측 ACT → RD/WR, PRE → ACT 간격은 `tRCD + 1`, `tRP + 1`이며 스펙보다 짧아지지 않는다.

```mermaid
stateDiagram-v2
  direction LR
  IDLE --> RD: hit, read
  IDLE --> WR: hit, write
  IDLE --> ACT: bank closed
  IDLE --> PRE: other row open
  PRE --> PRE_WAIT: PRE issued after tRAS
  PRE_WAIT --> ACT: tRP
  ACT --> ACT_WAIT: ACT issued after tRC
  ACT_WAIT --> RD: tRCD
  ACT_WAIT --> WR: tRCD
  RD --> RD_WAIT: RD issued
  RD_WAIT --> IDLE: data_valid
  WR --> WR_WAIT: WR issued
  WR_WAIT --> IDLE: tWR
```

### 스펙 요약

| 항목 | 값 |
| --- | --- |
| 주소 (14 bit) | `{bank[13:12], row[11:4], col[3:0]}`, 4 bank × 256 row × 16 col × 32 bit (64 KiB) |
| 타이밍 (cycle) | tRCD 3 · tRP 3 · tRAS 6 · tRC 9 · tCL 2 · tWR 2 · tRFC 12 · tREFI 64 |
| 명령 | NOP · ACT · RD · WR · PRE · REF (3 bit `dram_cmd_e`) |
| 호스트 인터페이스 | `req_*` / `rsp_*` valid/ready. WR도 응답한다(`rsp_rdata = 0`). `rsp_err`는 예약, v1은 0 |

상수는 [`rtl/dram_pkg.sv`](rtl/dram_pkg.sv) 한 곳에서 정의하고, [`docs/spec.md`](docs/spec.md)가 같은 값을 문서로 관리한다.

## 성능 분석

### 경로별 latency

호스트 accept부터 응답 handshake까지의 사이클 수다(`rsp_ready = 1`). v0는 같은 TB로 측정한 단일 FSM 컨트롤러(`64e73e0`)이고, v1 값은 현재 HEAD에서 다시 확인했다.

| 경로 | v0 | v1 | v1에서 늘어난 이유 |
| --- | ---: | ---: | --- |
| Page hit RD | 4 | 6 | 큐 단계 +1, 응답 버퍼 +1 |
| Closed-bank RD | 7 | 10 | 위에 더해 wait → issue handoff +1 |
| Closed-bank WR | 6 | 9–12 | 같음. 폭은 다른 뱅크와의 중재 때문 |
| Row-conflict RD | 11 | 14 | `PRE_WAIT`, `ACT_WAIT` 뒤 handoff가 각각 +1 |
| Row-conflict WR | 10 | 13–14 | 같음 |

### Throughput

| 지표 | v0 | v1 |
| --- | ---: | ---: |
| 4-bank write 4건, 첫 accept → 마지막 응답 | 35 cycles | **17 cycles (2.06×)** |
| 같은 사이클에 바쁜 뱅크 엔진 수 | 1 | 최대 4 |
| 연속 RD | — | 4사이클당 최대 1회 (read pipe 1개) |
| Refresh로 새 요청이 막힌 비율 | — | 23.3% (`make sim` 834사이클 중 194, REF 10회) |

Burst 구간에서는 8사이클 동안 매 사이클 명령이 나간다. 뱅크가 4개일 때 병목은 뱅크 타이밍이 아니라 사이클당 하나뿐인 명령 슬롯이다. 반대로 단독 요청은 큐와 응답 버퍼 단계 때문에 v0보다 2–3사이클 느리다.

REF 하나는 `tRFC + 2` = 14사이클과 그 앞의 drain 동안 요청을 막는다. drain이 없다면 14 / (64 + 14) ≈ 18%다. 시나리오 5에서는 응답이 막힌 read가 read pipe 하나로 4사이클마다 나가서 drain 한 번이 26사이클까지 길어지고, 그래서 실측이 더 높다.

![4-bank write burst 파형. 네 뱅크 엔진이 겹쳐 동작하고, 첫 accept부터 마지막 응답까지 17 cycles](docs/images/wave_4bank_burst.png)

<sub>TB 시나리오 4, commit `6049e5a`의 Verilator VCD. ① b0 accept. b1–b3가 2사이클 간격으로 들어오고 곧바로 dispatch된다. ② b0와 b2가 동시에 ACT를 기다리면 `rr_ptr`에 따라 b2가 먼저 나간다. 이 구간에서는 매 사이클 명령이 나간다. ③ 닫혀 있던 b2의 WR가 PRE가 필요한 b0, b1보다 먼저 끝난다. ④ 응답은 tag 순서(b0 → b1 → b2 → b3)로 4사이클 연속 나가고, 먼저 끝난 b2는 버퍼에서 기다린다.</sub>

### 설계 trade-off

| 선택 | 이점 | 대가 |
| --- | --- | --- |
| Open-page (auto-PRE 없음) | Hit 재사용, 뱅크별 지역성 | Row conflict마다 PRE + ACT |
| Drain-then-REF | 단순하고 예측 가능 | Latency 버블. `refi_cnt`를 REF가 끝난 뒤 다시 장전해 REF 간격이 tREFI + drain + tRFC로 늘어난다. REF 전에 PREA를 내지 않고 모델이 열린 row를 닫는다 |
| 깊이 4 큐 + 뱅크 엔진 | 뱅크별 대기를 가리고 다중 outstanding 요청을 받는다 | 단독 요청 +2–3 cycles. 명령 슬롯 1개, read pipe 1개 |
| Tag 기반 in-order 응답 | 호스트 계약이 단순하다 | 먼저 끝난 응답이 16 × 32b 버퍼에서 기다린다(FF의 약 절반) |
| Shadow open-row | 모델을 들여다보지 않고 스케줄한다 | `dram_model`과 상태를 맞춰야 한다 |

## 검증

### 회귀: `make sim`

[`tb/tb_mem_ctrl.sv`](tb/tb_mem_ctrl.sv)의 directed 시나리오 5개가 한 번에 돈다. 데이터 비교가 틀리거나 모델 `access_err`, `rsp_err`가 한 번이라도 나오면 실패다. 실패한 체크는 모두 `[TB] ERROR`로 찍고 끝까지 진행한 뒤, 요약을 출력하고 `$fatal`로 0이 아닌 코드로 끝난다.

| # | 시나리오 | 확인 내용 |
| --- | --- | --- |
| 1 | Page hit WR → RD | read-back 데이터 |
| 2 | Page miss (bank 0 row 변경) | PRE → ACT 경로, 새 row와 이전 row의 데이터 |
| 3 | Multi-bank + bank 0 conflict | bank 0의 row가 바뀐 뒤에도 bank 1 데이터 유지 |
| 4 | 4-bank write burst | 같은 사이클에 바쁜 뱅크 엔진 ≥ 2 (관측 4), 4개 word read-back |
| 5 | 응답 back-pressure | `rsp_ready`를 150사이클 내린 채 read 20건(tag 16개 초과): 20/20 순서와 데이터 일치, REF ≥ 1회 |

<details>
<summary>회귀 로그 (HEAD, Verilator 5.052)</summary>

```text
[TB] === SCENARIO 1: page hit WR→RD ===
[TB] hit RD OK (0xa5a55a5a)
[TB] === SCENARIO 2: page miss (bank0 row change) ===
[TB] miss-new RD OK (0xbeef0002)
[TB] miss-old RD OK (0xa5a55a5a)
[TB] === SCENARIO 3: multi-bank + bank0 conflict ===
[TB] bank1 RD OK (0xc0de0001)
[TB] bank0 conflict RD OK (0xd00d0004)
[TB] bank1 survived OK (0xc0de0001)
[TB] === SCENARIO 4: 4-bank write burst (bank engines in parallel) ===
[TB] peak bank engines active at once=4
[TB] q bank0 OK (0x10000000)
[TB] q bank1 OK (0x20000000)
[TB] q bank2 OK (0x30000000)
[TB] q bank3 OK (0x40000000)
[TB] === SCENARIO 5: response back-pressure (20 reads, rsp_ready low 150 cycles) ===
[TB] back-pressure OK (20/20 in order, 3 REF during the test)
[TB] access_err count=0 OK
[TB] rsp_err count=0 OK
[TB] PASS — hit/miss/multi-bank/burst/back-pressure OK
```

</details>

### 타이밍 규칙 검사

`dram_model`은 상태와 데이터만 모델링하고 명령 간격은 검사하지 않는다. 그래서 수정하지 않은 `tb_mem_ctrl`을 모니터로 감싸, `make sim`의 다섯 시나리오 전체(리셋 후 834사이클)에서 뱅크별 명령 간격을 쟀다. 간격은 두 이벤트를 샘플한 클럭 엣지 사이의 사이클 수다.

| 규칙 | 스펙 | 측정 최소 | 검사한 간격 | 위반 |
| --- | ---: | ---: | ---: | ---: |
| tRCD (ACT → RD/WR) | 3 | 4 | 58 | 0 |
| tRP (PRE → ACT) | 3 | 4 | 24 | 0 |
| tRAS (ACT → PRE) | 6 | 10 | 24 | 0 |
| tRC (ACT → ACT) | 9 | 14 | 50 | 0 |
| tWR (WR → PRE) | 2 | 14 | 11 | 0 |
| tCL (RD → `data_valid`) | 2 | 3 | 30 | 0 |
| tRFC (REF → 다음 명령) | 12 | 16 | 9 | 0 |

tRCD와 tRP가 스펙보다 1 긴 것은 위의 wait → issue handoff 때문이다. tCL이 1 긴 것은 모델이 RD를 받은 엣지에서 tCL 엣지 뒤에 `data_valid`를 레지스터로 올리고, 그 값이 다음 엣지에 샘플되기 때문이다. 이 모니터는 아직 저장소에 넣지 않았다. TB 안의 assertion으로 옮기는 일이 다음 단계에 있다.

### 코드 커버리지와 남은 구멍

| 모듈 | Line | Branch | Toggle |
| --- | ---: | ---: | ---: |
| `mem_ctrl` | 94.3% | 91.9% | 51.2% |
| `dram_model` | 100.0% | 83.3% | 75.7% |
| 전체 | 95.8% | 90.2% | 63.7% |

<sub>commit `6049e5a`, Verilator line/toggle coverage 빌드. 시나리오 5가 더해지기 전의 측정이다.</sub>

아직 닫지 못한 구멍은 [`docs/coverage.md`](docs/coverage.md)에 정리했다.

- 시나리오 5가 큐 4슬롯을 모두 채우지만, 오래된 엔트리를 앞질러 dispatch하는 경우(out-of-order dispatch)는 일어나지 않는다. 시나리오 1–4는 호스트 task가 응답을 기다려 점유가 1 이하다
- 열린 row로 바로 가는 write-hit 경로에 도달하지 않는다
- `access_err` 경로(PRE 누락, 잘못된 row)를 일부러 일으키는 negative test가 없다
- 네 뱅크가 모두 바쁠 때 REF가 걸리는 경우, random traffic, coverage bin이 없다

## 디버그: 응답 back-pressure에서 태그 wrap-around

[`docs/coverage.md`](docs/coverage.md)에 gap으로 적어 둔 back-pressure를 실험 TB로 재현하다가 찾은 버그다.

- **증상**: `rsp_ready`를 150사이클 내린 채 read 20건을 보내면, 풀린 뒤 앞의 4건이 엉뚱한 데이터를 돌려주고 뒤의 4건은 응답이 오지 않았다(16/20).
- **원인**: `req_ready`가 큐의 빈 슬롯만 확인했다. 큐는 dispatch로 계속 비므로, 응답이 막혀 있어도 요청을 계속 받았다. 4-bit `tag_alloc`이 16을 돌아 아직 반환되지 않은 tag를 다시 할당했고, 17번째 read가 첫 번째 read의 버퍼 엔트리를 덮어썼다.
- **수정** (`fa08330`): 처리 중인 요청이 15개면 새 요청을 받지 않는다.

```diff
- req_ready = free_found && !ref_due && !ref_active;
+ req_ready = free_found && !ref_due && !ref_active &&
+             (TAG_BITS'(tag_alloc + 1'b1) != tag_retire);
```

- **회귀** (`7e2d4b5`): 시나리오 5로 고정했다. 수정 전 RTL은 첫 응답에서 `0x50000010`(17번째 read의 데이터)을 돌려줘 실패하고, 수정 후에는 20/20이 순서대로 돌아온다.

![back-pressure 해제 구간 파형. 수정 전에는 앞 4건의 데이터가 틀리고 뒤 4건이 누락되며, 수정 후에는 20건이 순서대로 반환된다](docs/images/wave_backpressure_fix.png)

<sub>`rsp_ready`가 풀리는 구간. 위 세 줄은 수정 전, 아래 두 줄은 수정 후다. 수정 전에는 tag 4 자리에 17번째 read의 데이터(`10`)가 나가고 16건 뒤 `rsp_valid`가 내려간다. 수정 후에는 `00`부터 `13`까지 20건이 순서대로 나간다.</sub>

같은 재검증에서 나온 나머지 항목은 PDF 19쪽에 정리했다. 병렬성 체크의 근거가 약했던 항목 C는 `7e2d4b5`에서 고쳤다. "open bank ≥ 2" 대신 동시에 바쁜 뱅크 엔진 수로 판정한다. Handoff +1(B), out-of-order dispatch와 write-hit 미검증(D), 모델 체커 경로 미검증(E)은 다음 단계에 남아 있다.

## PPA

sv2v → Yosys 0.52 → Nangate45 typical (OpenSTA 예제 라이브러리) → OpenSTA 3.1. `mem_ctrl` 단독이고 배선과 클럭 트리는 포함하지 않는다. 절대값보다 버전 사이의 상대 비교에 쓰는 수치다.

| | v0 단일 FSM | v1 (`6049e5a`) | v1 + tag 수정 (`fa08330`) |
| --- | ---: | ---: | ---: |
| Area (µm²) | 1,208 | 9,819 | 9,692 |
| Cell | 559 | 4,414 | 4,433 |
| FF | 131 | 1,072 | 1,072 |
| reg2reg (ns) | 0.809 | 2.642 | 2.880 |
| ≈ fmax (MHz) | 1,182 | 373 | 343 |

- **면적의 58%가 플롭이다.** 응답 버퍼 하나가 528 FF(전체 면적의 29%)이고, 데이터를 담는 플롭 768개가 전체 FF의 72%다.
- **Critical path** (v1, 29 levels, 2.642 ns): `tag_retire` → `q_tag − tag_retire` 나이 비교 → 슬롯 선택 → page 판정 → `b_state`. fanout 46인 NOR4 한 단이 0.866 ns(33%)를 차지한다.
- **줄일 수 있는 곳** (추정, 미측정): 데이터 플롭은 리셋이 필요 없다(약 −613 µm²). `b_timer`는 8 bit에서 2 bit로 충분하다(−24 FF). `b_wdata` 128 FF는 `q_wdata`의 복사본이라 슬롯 인덱스를 넘기면 없앨 수 있다.

<details>
<summary>FF 구성 (v1, 1,072 FF)</summary>

| 블록 | FF | FF 면적 (µm²) | 주요 레지스터 |
| --- | ---: | ---: | --- |
| 응답 버퍼 | 528 | 2,809 | `rsp_data` 512, `rsp_done` 16 |
| 뱅크 엔진 ×4 | 248 | 1,319 | `b_wdata` 128, `b_addr` 48, `b_timer` 32, `b_state` 16 |
| 요청 큐 ×4 | 211 | 1,123 | `q_wdata` 128, `q_addr` 56, `q_tag` 16, `q_valid` 4 |
| Shadow open-row | 64 | 340 | `bank_row` 32, `rc_rem` 16, `ras_rem` 12, `bank_open` 4 |
| 기타 | 21 | 112 | `refi_cnt` 7, `tag_alloc` 4, `tag_retire` 4, `rd_bank_q` 2 |

</details>

## 실행 방법

**Verilator 5.x**(`--binary`, `--timing`)와 `make`가 필요하다. Ubuntu 22.04의 apt 패키지는 Verilator 4.x이므로 Ubuntu 24.04 이상을 쓰거나 소스에서 빌드한다.

```bash
git clone https://github.com/yhkwon-git/mini-dram-controller.git
cd mini-dram-controller
make check-tools     # verilator, python3, cocotb 확인
make sim             # 시나리오 5개 → [TB] PASS
make sim WAVES=1     # tb_mem_ctrl.vcd도 기록
make lint            # Verilator lint-only
```

- **Windows**: WSL에 Verilator를 설치하고 저장소 폴더에서 `wsl make sim`
- **cocotb (선택, ≥ 2.0)**: `pip install cocotb && make sim-cocotb`. 리셋 직후 idle 상태만 보는 smoke test다
- 빌드 결과는 `obj_dir/`에 생기며 git에서 제외된다

## 저장소 구조

```text
rtl/
  dram_pkg.sv                  파라미터, 명령 enum, 주소 헬퍼
  host_if.sv                   호스트 valid/ready (조합 pass-through)
  mem_ctrl.sv                  큐, dispatch, 뱅크 엔진 ×4, arbiter, refresh, 응답 버퍼
  dram_model.sv                뱅크, open row, tCL, tRFC, access_err (TB용 행동 모델)
  mem_ctrl_top.sv              세 블록 연결
tb/
  tb_mem_ctrl.sv               directed 시나리오 5개 (make sim)
  test_mem_ctrl.py             cocotb smoke test
  cocotb_runner.py             cocotb 빌드와 실행 (make sim-cocotb)
docs/
  spec.md                      주소 맵, 타이밍, 명령, 호스트 IF, 스케줄러, refresh
  scheduler-throughput.md      latency, throughput, trade-off
  coverage.md                  커버리지와 남은 gap
  images/                      README 파형 그림
portfolio-deck/                포트폴리오 PDF, PPTX
Makefile                       sim, lint, sim-cocotb, clean
```

## 문서

| 문서 | 내용 |
| --- | --- |
| [스펙](docs/spec.md) | 주소 맵, 타이밍 파라미터, 명령 집합, 호스트 인터페이스 규칙, 스케줄러와 refresh 정책, 구현 상태 |
| [스케줄러 latency · throughput](docs/scheduler-throughput.md) | 경로별 latency (v0 대비), burst throughput, refresh 비용, trade-off, 다음 개선점 |
| [커버리지](docs/coverage.md) | 시나리오별 확인 항목, TB/RTL 내부 체크, 아직 자동화하지 못한 gap |
| [포트폴리오 PDF](portfolio-deck/MiniDramController_Portfolio.pdf) | 아키텍처 비교, RTL 구현, 파형, 디버그, PPA를 21쪽으로 정리 |

## 다음 단계

- [ ] tREFI 카운터를 REF와 무관하게 돌리고 postpone 한도를 둬서 평균 REF 간격을 tREFI로 맞추기. REF 전에 PREA 발행
- [ ] `dram_busy` 입력 대신 컨트롤러가 tRFC를 직접 세기 (실제 DRAM에는 busy 신호가 없다)
- [ ] 네 뱅크가 바쁠 때 REF가 걸리는 회귀 추가
- [ ] 대기 상태가 끝나는 사이클에 바로 명령 발행 (handoff −1 cycle)
- [ ] 뱅크를 섞은 non-blocking 호스트로 out-of-order dispatch와 write-hit 경로 검증
- [ ] 명령 간격 모니터를 TB 안의 assertion으로 옮기고 `access_err` negative test 추가
- [ ] 응답 버퍼와 `b_timer`를 줄인 뒤 면적 재측정

## 관련 프로젝트

[High-Speed Link Lite](https://github.com/yhkwon-git/High_Speed_Link_Lite): HBM base die 디지털 링크 1채널 슬라이스. 그 프로젝트의 메모리 컨트롤러는 큐 head만 발행하는 in-order 구조이고, 이 저장소는 그다음 단계인 뱅크 병렬 처리, tag 기반 응답 재정렬, refresh 스케줄링을 구현했다.

## License

MIT. [LICENSE](LICENSE)를 본다.
