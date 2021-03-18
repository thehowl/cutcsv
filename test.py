import subprocess
import sys

test_cases = {
    "base":	        [["-f", "1"], b"a,b,c\n", b"a\n"],
    "base2":            [["-f", "2"], b"a,b,c\n", b"b\n"],
    "base3":	        [["-f", "3"], b"a,b,c\n", b"c\n"],
    "no_lf":	        [["-f", "3"], b"a,b,c", b"c\n"],
    "no_lf1":	        [["-f", "1"], b"a,b,c", b"a\n"],
    "two_lines":	[["-f", "1"], b"a,b,c\nd,e,f\n", b"a\nd\n"],
    "delim":	        [["-f1", "-d#"], b"a#b#c\n", b"a\n"],
    "cr":	        [["-f3"], b"a,b,c\r\n", b"c\n"],
    "quoted":	        [["-f1"], b'"quoted "" string",2,3', b'quoted " string\n'],
    "quoted_start":	[["-f1"], b'""" string",2,3', b'" string\n'],
    "quoted_end":	[["-f1"], b'"quoted """,2,3', b'quoted "\n'],
    "quoted_only":	[["-f1"], b'"""",2,3', b'"\n'],
    "multiple":         [["-f1-2,4,6-"], b"1,2,3,4,5,6", b"1,2,4,6\n"],
    "until":            [["-f-3"], b"1,2,3,4,5,6", b"1,2,3\n"],
    "from":             [["-f3-"], b"1,2,3,4,5,6", b"3,4,5,6\n"],
}

exit_code = 0

for k in test_cases.keys():
    v = test_cases[k]
    args = ["./cutcsv"]
    args.extend(v[0])
    call = subprocess.run(args, input=v[1], capture_output=True)
    k += ":"
    if call.returncode != 0:
        print("{0: <16} fail (return code: {1})".format(k, call.returncode))
        exit_code = 1
        continue
    if call.stdout != v[2]:
        print("{0: <16} fail (wrong return output)".format(k))
        exit_code = 1
        continue
    print("{0: <16} success".format(k))

if exit_code == 0:
    print("everything is green!")

sys.exit(exit_code)
