# Tuya Plug Enhanced

SmartThings Edge 지그비 Tuya 플러그 보강 드라이버

[영어 문서 보기](README.en.md)

## 출처와 라이선스

이 드라이버는 아래 원본 저장소의 `tuya-plug`를 포크해 수정했습니다.

- 원본 저장소: <https://github.com/iquix/ST-Edge-Driver/tree/master/tuya-plug>
- 원본 작성자: Jaewon Park (iquix)
- 원본 라이선스: Apache-2.0

원본 파일의 저작권·라이선스 고지는 `src/init.lua`와 `LICENSE`에 유지했습니다.
변경 사항과 출처는 `NOTICE.md`에도 기록했습니다.

## 지원 장치

- Tuya `TS011F`
- Tuya `TS0121`

## 추가 기능

- 설정 화면 한국어화
- 전압 측정
- 장치가 전류를 보고하면 실제 전류값 사용
- 전압 센서가 없으면 고정 전압 사용
- 전류 센서가 없고 전력값이 있으면 `전력 ÷ 전압`으로 전류 계산
- 전력 센서가 없고 전류값이 있으면 `전압 × 전류`로 전력 계산

계산값은 실제 센서값이 아닌 대체 계산값입니다.

## 갱신 주기 설정

전력 자동 조회는 다음 방식으로 설정할 수 있습니다.

- 가변 5~15초: 기본값
- 가변 5~30초
- 10초 고정
- 30초 고정
- 60초 고정
- 300초 고정
- 수동 갱신

추가로 에너지 조회 주기와 전압·전류·전력 보고 주기도 설정할 수 있습니다.

## SmartThings 설치

아래 초대 링크로 SmartThings Edge 채널에 참여합니다.

<https://bestow-regional.api.smartthings.com/invite/Boj0wXyx8qlA>

채널 참여 후:

1. 허브에 `Tuya Plug Enhanced by iquix`를 설치합니다.
2. SmartThings 앱에서 Tuya 플러그를 엽니다.
3. 드라이버를 `Tuya Plug Enhanced by iquix`로 전환합니다.
4. 설정에서 갱신 주기와 전압 대체값을 조정합니다.
