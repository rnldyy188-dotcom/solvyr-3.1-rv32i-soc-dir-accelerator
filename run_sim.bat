@echo off
REM ============================================================================
REM run_sim.bat  -  Windows runner for the Solvyr-3 testbenches (native Icarus)
REM
REM For Windows users who installed Icarus Verilog and Python natively (no WSL).
REM Open Command Prompt in this folder and type, e.g.:
REM     run_sim.bat bench
REM     run_sim.bat all
REM Targets: prim system csr irq gpio timer uart accel bench all (default: all)
REM
REM (On Linux / macOS / WSL use ./run_sim.sh instead.)
REM ============================================================================
setlocal
cd /d "%~dp0"

set "CORE=rtl\alu.v rtl\regfile.v rtl\imm_gen.v rtl\decoder.v rtl\control_unit.v rtl\forwarding_unit.v rtl\hazard_unit.v rtl\branch_unit.v rtl\load_store_unit.v rtl\pipeline_regs.v rtl\csr_file.v rtl\imem_bram.v rtl\dmem_bram.v rtl\solvyr3_core.v"
set "SOC=%CORE% rtl\mm_interconnect.v rtl\gpio.v rtl\timer.v rtl\uart_rx_core.v rtl\uart.v rtl\dsp_mac.v rtl\dpram_be.v rtl\dir_accel.v rtl\prog_loader.v rtl\solvyr3_soc.v"
set "PRIM=rtl\alu.v rtl\regfile.v rtl\imm_gen.v rtl\decoder.v rtl\control_unit.v rtl\load_store_unit.v rtl\branch_unit.v rtl\forwarding_unit.v rtl\hazard_unit.v"

set "T=%1"
if "%T%"=="" set "T=all"

REM Regenerate the test programs if Python is available (harmless if not).
where python >nul 2>nul && ( python tools\rv32i.py >nul 2>nul & python tools\gen_bench.py >nul 2>nul )

if /i "%T%"=="prim"   goto prim
if /i "%T%"=="system" goto system
if /i "%T%"=="csr"    goto csr
if /i "%T%"=="irq"    goto irq
if /i "%T%"=="gpio"   goto gpio
if /i "%T%"=="timer"  goto timer
if /i "%T%"=="uart"   goto uart
if /i "%T%"=="accel"  goto accel
if /i "%T%"=="bench"  goto bench
if /i "%T%"=="all"    goto all
echo usage: run_sim.bat {prim^|system^|csr^|irq^|gpio^|timer^|uart^|accel^|bench^|all}
goto :eof

:prim
echo === prim ===
iverilog -g2012 -I rtl -o build_prim tb\tb_primitives.v %PRIM% && vvp build_prim
goto :eof
:system
echo === system ===
iverilog -g2012 -I rtl -o build_system tb\tb_system.v %SOC% && vvp build_system
goto :eof
:csr
echo === csr ===
iverilog -g2012 -I rtl -o build_csr tb\tb_csr.v %SOC% && vvp build_csr
goto :eof
:irq
echo === irq ===
iverilog -g2012 -I rtl -o build_irq tb\tb_irq.v %SOC% && vvp build_irq
goto :eof
:gpio
echo === gpio ===
iverilog -g2012 -I rtl -o build_gpio tb\tb_gpio.v %SOC% && vvp build_gpio
goto :eof
:timer
echo === timer ===
iverilog -g2012 -I rtl -o build_timer tb\tb_timer.v rtl\timer.v && vvp build_timer
goto :eof
:uart
echo === uart ===
iverilog -g2012 -I rtl -o build_uart tb\tb_uart.v rtl\uart.v rtl\uart_rx_core.v && vvp build_uart
goto :eof
:accel
echo === accel ===
iverilog -g2012 -I rtl -o build_accel tb\tb_dir_accel.v rtl\dir_accel.v rtl\dsp_mac.v rtl\dpram_be.v && vvp build_accel
goto :eof
:bench
echo === bench ===
iverilog -g2012 -I rtl -o build_bench bench\tb_bench.v %SOC% && vvp build_bench
goto :eof

:all
call :prim
call :system
call :csr
call :irq
call :gpio
call :timer
call :uart
call :accel
call :bench
echo === all testbenches built and run ===
goto :eof
