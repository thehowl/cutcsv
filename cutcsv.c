#include<stdio.h>
#include<stdint.h>
#include<sys/stat.h>
#include<errno.h>
#include<string.h>
#include<stdlib.h>
#include<stdbool.h>

#define VERSION "0.1.0"

/* flag parsing ------------------------------------------------------------- */

struct flag_info {
	/* file to use */
	int32_t  file_count;
	char**   files;
	/* fields to print */
	int32_t  field_count;
	int32_t* fields;
	/* defaults to comma */
	char     delim;
	bool     verbose;
	/* delimiter used for when we have multiple fields.
	 * defaults to delim */
	char*    out_delim;

	bool should_exit;
};

struct flag_info* failed_flaginfo;

struct flag_info*
parse_print_usage(char* prog, char* reason) {
	if (reason != NULL)
		fprintf(stderr, "%s: %s\n\n", prog, reason);
	fprintf(stderr, "%s - the csv swiss army knife (version %s)\n\n\
Usage: %s OPTION... [FILE]\n\
Print selected CSV fields from each specified FILE to standard output.\n\
With no FILE, or when FILE is -, read standard output.\n\
\n\
	-f <LIST>   Print the specified comma-separated list of fields or ranges (required)\n\
	-d <CHAR>   Use CHAR as a delimiter (defaults to ',')\n\
	-D <STRING> Use STRING as the output separator (in case of multiple fields).\n\
	            Defaults to the input delimiter.\n\
	-v          Be verbose\n", prog, VERSION, prog);

	return failed_flaginfo;
}

struct flag_info*
parse_flags(int32_t argc, char* argv[]) {
	int32_t i;
	char* arg;
	struct flag_info* ret;
	char* prog;
	bool parsing_files = false;
	int32_t current_file = 0;
	char* flag_arg;
	bool used_next;
	int32_t field_num;
	char* invalid_reason;

	invalid_reason = (char*) calloc(200, 1);
	prog = argv[0];
	ret = calloc(1, sizeof(struct flag_info));
	ret->delim = ',';

	for (i = 1; i < argc; i++) {
		arg = argv[i];
		used_next = false;
		flag_arg = NULL;

		if (arg == NULL || arg[0] == '\x00') {
			sprintf(invalid_reason, "invalid argument %d: is empty string or null", i);
			return parse_print_usage(prog, invalid_reason);
		}

		/* parse as file */
		if (arg[0] != '-' || strlen(arg) == 1) {
			if (!parsing_files) {
				parsing_files = true;
				ret->file_count = argc - i;
				ret->files = calloc(1, sizeof(char*));
			}
			if (strlen(arg) == 1 && arg[0] == '-') {
				arg = "/dev/stdin";
			}
			ret->files[current_file] = calloc(strlen(arg)+1, sizeof(char));
			memcpy(ret->files[current_file], arg, strlen(arg));
			current_file++;
			continue;
		}

		/* disallow passing flags after they've been terminated */
		if (parsing_files)
			return parse_print_usage(prog, "invalid flag while parsing files");

		flag_arg = &arg[2];
		if (*flag_arg == '\x00' && argc != i+1) {
			flag_arg = argv[i+1];
			used_next = true;
		}

		/* use advance_arg for when you used the argument to the flag */
#define advance_arg() i += (used_next ? 1 : 0)

		switch (arg[1]) {
		case 'f':
			/* field flag */
			/* TODO: make it work for more than one field */
			field_num = atoi(flag_arg);
			if (field_num <= 0)
				return parse_print_usage(prog, "invalid field");
			ret->field_count = 1;
			ret->fields = calloc(1, sizeof(int32_t));
			ret->fields[0] = field_num;
			advance_arg();
			break;
		case 'd':
			/* delim flag */
			if (strlen(flag_arg) != 1) {
				sprintf(invalid_reason, "invalid length for delimiter: need 1 got %ld", strlen(flag_arg));
				return parse_print_usage(prog, invalid_reason);
			}

			ret->delim = flag_arg[0];
			advance_arg();
			break;
		case 'D':
			/* output delimiter */
			ret->out_delim = flag_arg;
			advance_arg();
			break;
		case 'h':
			return parse_print_usage(prog, NULL);
		case 'v':
			ret->verbose = true;
			break;
		default:
			sprintf(invalid_reason, "unknown flag '%c'", arg[1]);
			return parse_print_usage(prog, invalid_reason);
		}
	}

	if (ret->field_count == 0)
		return parse_print_usage(prog, "no field number provided");
	if (ret->file_count == 0) {
		ret->file_count = 1;
		ret->files = malloc(sizeof(char**));
		ret->files[0] = "/dev/stdin";
	}
	if (ret->out_delim == NULL) {
		ret->out_delim = calloc(2, sizeof(char));
		ret->out_delim[0] = ret->delim;
	}

	return ret;
}

/* main program ------------------------------------------------------------- */

/* determine whether a field should be printed based on the flags. */
bool
should_print_field(struct flag_info* flags, int num) {
	int i;

	for (i = 0; i < flags->field_count; i++) {
		if (flags->fields[i] == num)
			return true;
	}

	return false;
}

#define BUF_SIZE 1 << 13
#define verbose(...)\
	if (flags->verbose) fprintf(stderr, __VA_ARGS__)

int32_t
main(int32_t argc, char* argv[]) {
	struct flag_info* flags;
	int32_t i;
	FILE* file;
	char* buf;

	/* parse state */
	size_t read;
	int32_t pos;
	int32_t field_num;
	bool in_quotes;
	char last_char = 0;
	char* to_print;
	size_t to_print_sz = BUF_SIZE;
	int32_t to_print_pos = 0;
	bool should_print;
	int32_t num_printed;

	/* init globals */
	failed_flaginfo = calloc(1, sizeof(struct flag_info));
	failed_flaginfo->should_exit = true;

	/* parse flags */
	flags = parse_flags(argc, argv);
	if (flags->should_exit)
		return 1;

	verbose("flags parsed\n");

	/* allocate buffers */
	buf = malloc(BUF_SIZE);
	to_print = calloc(BUF_SIZE, 1);

	for (i = 0; i < flags->file_count; i++) {
		in_quotes = false;
		should_print = should_print_field(flags, 1);
		read = 0;
		pos = 0;
		field_num = 1;
		num_printed = 0;

		verbose("opening file %s\n", flags->files[i]);

		file = fopen(flags->files[i], "rb");
		if (file == NULL) {
			fprintf(stderr, "could not open %s\n", flags->files[i]);
			return 1;
		}
#define addchar(x) \
	if (!should_print) continue;\
	if (to_print_pos+1 >= to_print_sz) {\
		to_print = realloc(to_print, to_print_sz * 2);\
		memset(&to_print[to_print_sz], 0, to_print_sz);\
		to_print_sz *= 2;\
	} \
	to_print[to_print_pos++] = x;\
	last_char = x
		for (read = fread(buf, 1, BUF_SIZE, file); read != 0; read = fread(buf, 1, BUF_SIZE, file)) {
			for (pos = 0; pos < read; pos++) {
				/* no proper handling for CR, if you're using windows that's your fault */
				if (buf[pos] == '\r')
					continue;
				if (buf[pos] == '"') {
					/* quote: handle double quotes, otherwise use to start/end field */
					if (!in_quotes && last_char == '"') {
						in_quotes = true;
						addchar('"');
						continue;
					}
					if (in_quotes) {
						in_quotes = false;
						last_char = '"';
						continue;
					}
					if (last_char != '\n' && last_char != 0 && last_char != flags->delim) {
						/* assume literal " */
						addchar('"');
						continue;
					}
					/* we set last_char to 0 so that we can have fields which start
					 * with a quote and are quoted, eg. """hello,"" said Plato" */
					in_quotes = true;
					last_char = 0;
					continue;
				}
				if (in_quotes || (buf[pos] != '\n' && buf[pos] != flags->delim)) {
					addchar(buf[pos]);
					continue;
				}
				/* \n or delim, in any case we are changing field.
				 * dump current field if we should print it */
				if (should_print) {
					if (num_printed > 0)
						fputs(flags->out_delim, stdout);
					fwrite(to_print, sizeof(char), to_print_pos, stdout);
					to_print_pos = 0;
					num_printed++;
				}
				if (buf[pos] == '\n') {
					if (num_printed > 0)
						fputc('\n', stdout);
					field_num = 1;
					num_printed = 0;
				} else {
					field_num++;
				}
				last_char = 0;
				should_print = should_print_field(flags, field_num);
			}
		}

		/* print last one in case we are missing a newline at the end of the
		 * file. notice we check to_print_pos to account for empty lines (last line) */
		if (should_print && to_print_pos != 0) {
			if (num_printed > 0)
				fputs(flags->out_delim, stdout);
			fwrite(to_print, sizeof(char), to_print_pos, stdout);
			to_print_pos = 0;
			num_printed++;
		}

		if (num_printed != 0)
			fputc('\n', stdout);
		fclose(file);
	}

	return 0;
}
