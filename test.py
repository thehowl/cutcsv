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
    "colr":             [["-rcname"], b"a,b,name,c\na,b,adolfo,c\n", b"adolfo\n"],
    "col":              [["-cname"], b"a,b,name,c\na,b,adolfo,c\n", b"name\nadolfo\n"],
    "col_field":        [["-f1", "-ca", "-cb"], b"1,2,3,a,b,c\n", b"1,a,b\n"],
}

exit_code = 0

def file_put(filename, data):
    with open(filename, 'wb') as f:
        f.write(data)

def run_tests(is2x):
    for k in test_cases.keys():
        v = test_cases[k]
        args = ["./cutcsv"]
        args.extend(v[0])
        if is2x:
            file_put('/tmp/cutcsv-a', v[1])
            file_put('/tmp/cutcsv-b', v[1])
            args.extend(['/tmp/cutcsv-a', '/tmp/cutcsv-b'])
        call = subprocess.run(args, input=None if is2x else v[1], capture_output=True)
        k += ":"
        if call.returncode != 0:
            print("{0: <16} fail (return code: {1})".format(k, call.returncode))
            exit_code = 1
            continue
        output_want = (v[2] * 2) if is2x else v[2]
        if call.stdout != output_want:
            print("{0: <16} fail (wrong return output)".format(k))
            print(f"wanted: {output_want}\ngot:    {call.stdout}")
            exit_code = 1
            continue
        print("{0: <16} success".format(k))

run_tests(False)

print("""running 2x tests...
(these make sure that the state-clearing logic works correctly,
and given two identical files the output is simply duplicated)""")

run_tests(True)

if exit_code == 0:
    print("everything is green!")

sys.exit(exit_code)
