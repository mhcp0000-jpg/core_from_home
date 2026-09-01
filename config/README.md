# SoC project configuration

`soc_project.json`은 기본 memory map과 DPI Host 실행값을 기록합니다. 실제 RTL의
기본 주소는 `rtl/soc/rv_soc_pkg.sv`가 소유하며, 두 파일을 수동으로 각각 수정하는
대신 `scripts/configure_project.py`로 새 프로젝트를 생성하는 방식을 권장합니다.

생성기는 새 폴더에서 다음 파일을 같은 설정으로 맞춥니다.

- `rtl/soc/rv_soc_pkg.sv`
- C linker script와 C/assembly MMIO 주소
- `config/soc_memory_map.h`, `config/soc_memory_map.inc`
- parameterized BootROM WFI image
- DPI Host 기본 ELF, artifact 경로와 Windows/Linux 실행 wrapper

`soc_project.example.json`을 복사해 비대화형 생성 입력으로 사용할 수 있습니다.
