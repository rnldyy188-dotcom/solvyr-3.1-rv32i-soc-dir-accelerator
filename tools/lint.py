#!/usr/bin/env python3
# ============================================================================
# lint.py  -  Lightweight structural sanity check for the Verilog sources.
#
# Not a full parser: strips comments/strings, then verifies keyword-pair
# balance (module/endmodule, begin/end, case/endcase, function/endfunction,
# task/endtask, generate/endgenerate) and parenthesis balance per file, and
# checks that every module instantiated is defined somewhere in the tree.
# Catches the common "missing end*/extra )" class of error when no Verilog
# simulator is available. Run:  python3 tools/lint.py
# ============================================================================
import os, re, sys, glob

def strip(code):
    code = re.sub(r'/\*.*?\*/', ' ', code, flags=re.S)      # block comments
    code = re.sub(r'//[^\n]*', ' ', code)                    # line comments
    code = re.sub(r'"(\\.|[^"\\])*"', '""', code)            # string literals
    return code

PAIRS = [('module','endmodule'), ('begin','end'), ('case','endcase'),
         ('casex','endcase'), ('casez','endcase'), ('function','endfunction'),
         ('task','endtask'), ('generate','endgenerate')]

# Verilog/SystemVerilog keywords that are NOT module instantiations.
KEYWORDS = set("""module endmodule begin end case casex casez endcase function
endfunction task endtask generate endgenerate if else for while repeat forever
assign always initial wire reg input output inout parameter localparam integer
genvar posedge negedge or and not xor buf default signed unsigned real time
disable wait fork join return logic always_comb always_ff always_latch
typedef enum struct packed automatic void""".split())

def count_kw(code, kw):
    return len(re.findall(r'\b'+kw+r'\b', code))

def check_balance(path, code):
    errs = []
    # case/casex/casez all close with endcase
    n_case = count_kw(code,'case')+count_kw(code,'casex')+count_kw(code,'casez')
    n_endcase = count_kw(code,'endcase')
    if n_case != n_endcase:
        errs.append("case(%d) != endcase(%d)" % (n_case, n_endcase))
    for a,b in PAIRS:
        if a in ('case','casex','casez'): continue
        na, nb = count_kw(code,a), count_kw(code,b)
        if na != nb:
            errs.append("%s(%d) != %s(%d)" % (a,na,b,nb))
    if code.count('(') != code.count(')'):
        errs.append("parens ( %d != ) %d" % (code.count('('), code.count(')')))
    if code.count('{') != code.count('}'):
        errs.append("braces { %d != } %d" % (code.count('{'), code.count('}')))
    return errs

def module_defs(code):
    return re.findall(r'\bmodule\s+(\w+)', code)

def instantiations(code):
    # crude: "modname #(...) inst (" or "modname inst ("
    insts = set()
    for m in re.finditer(r'\b([A-Za-z_]\w*)\s*(?:#\s*\([^;]*?\))?\s+[A-Za-z_]\w*\s*\(', code):
        name = m.group(1)
        if name not in KEYWORDS:
            insts.add(name)
    return insts

def main():
    root = os.path.normpath(os.path.join(os.path.dirname(__file__), '..'))
    files = sorted(glob.glob(os.path.join(root,'rtl','*.v')) +
                   glob.glob(os.path.join(root,'tb','*.v')) +
                   glob.glob(os.path.join(root,'bench','*.v')))
    all_defs = set()
    all_insts = {}
    total_err = 0
    print("== balance check ==")
    for f in files:
        code = strip(open(f).read())
        errs = check_balance(f, code)
        for d in module_defs(code): all_defs.add(d)
        all_insts[f] = instantiations(code)
        tag = "OK " if not errs else "ERR"
        if errs: total_err += 1
        print("  [%s] %-28s %s" % (tag, os.path.basename(f), "; ".join(errs)))

    print("== module reference check ==")
    # known primitive/library cells we don't define (Xilinx unisim, guarded)
    library = {'MMCME2_BASE','BUFG','IBUF','OBUF'}
    missing = 0
    for f, insts in all_insts.items():
        for name in sorted(insts):
            if name not in all_defs and name not in library:
                # filter obvious false positives (control keywords already removed)
                print("  [WARN] %s instantiates undefined '%s'" % (os.path.basename(f), name))
                missing += 1
    print("  modules defined: %d" % len(all_defs))
    print("== summary ==")
    print("  balance errors: %d ; undefined-instance warnings: %d" % (total_err, missing))
    sys.exit(1 if total_err else 0)

if __name__ == '__main__':
    main()
