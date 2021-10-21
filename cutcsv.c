#include<limits.h>
#include<stdint.h>
#include<errno.h>
#include<string.h>
#include<stdlib.h>
#include<stdbool.h>
#include<stdio.h>

#define VERSION "0.2.0"

/* flag parsing ------------------------------------------------------------- */

struct field_spec {
	int32_t min;
	int32_t max;
	char*   col_name;
};

struct flag_info {
	/* file to use */
	size_t   file_count;
	char**   files;
	/* fields to print */
	size_t   field_count;
	struct field_spec* fields;
	/* defaults to comma */
	char     delim;
	bool     verbose;
	/* delimiter used for when we have multiple fields.
	 * defaults to delim */
	char*    out_delim;
	/* how many rows to skip from the top of the file */
	int32_t  skip_rows;

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
Select one or more fields using -c and -f. At least one field must be selected.\n\
With no FILE, or when FILE is -, read standard output.\n\
\n\
	-f <LIST>   Print the specified comma-separated list of fields or ranges\n\
	-c <COLUMN> Select fields whose column name (value of the first line)\n\
	            matches COLUMN.\n\
	-d <CHAR>   Use CHAR as a delimiter (defaults to ',')\n\
	-D <STRING> Use STRING as the output separator (in case of multiple fields).\n\
	            Defaults to the input delimiter.\n\
	-r          Skip one row from the top of the file (header).\n\
	-h          Show this help message.\n\
	-v          Be verbose\n", prog, VERSION, prog);

	return failed_flaginfo;
}

#define verbose(...)\
	if (flags->verbose) fprintf(stderr, __VA_ARGS__)

/* parse comma-separated ranges of fields */
bool
parse_field_spec(struct flag_info* flags, char* arg) {
	char c;
	struct field_spec fs = {0, 0, NULL};
	bool parsed_one = false;

	while (arg[0] != 0) {
		c = arg[0];
		/* if we're looking at a number, parse it */
		if (c >= '0' && c <= '9') {
			fs.min = strtoul(arg, &arg, 10);
			fs.max = fs.min;
			c = arg[0];
		}
		/* with a dash, we're looking at a upper number */
		if (c == '-') {
			/* default to max int32 */
			fs.max = INT_MAX;
			arg = &arg[1];
			c = arg[0];
			if (c >= '0' && c <= '9') {
				fs.max = strtoul(arg, &arg, 10);
				c = arg[0];
			}
		}
		if (c != ',' && c != 0) {
			return false;
		}
		if (c == ',')
			arg = &arg[1];

		/* store */
		flags->fields = realloc(flags->fields, ++flags->field_count * sizeof(struct field_spec));
		flags->fields[flags->field_count-1] = fs;
		parsed_one = true;
		verbose("parse field spec min %d max %d\n", fs.min, fs.max);
	}

	return parsed_one;
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
			snprintf(invalid_reason, 200, "invalid argument %d: is empty string or null", i);
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

		while (arg[1] != 0) {
			flag_arg = &arg[2];
			if (*flag_arg == 0 && argc != i+1) {
				flag_arg = argv[i+1];
				used_next = true;
			}

			/* use advance_arg for when you used the argument to the flag */
#define advance_arg() i += (used_next ? 1 : 0); goto break_upper_loop;

			switch (arg[1]) {
			case 'f':
				/* field flag */
				if (!parse_field_spec(ret, flag_arg)) {
					snprintf(invalid_reason, 200, "invalid field spec: %s", flag_arg);
					return parse_print_usage(prog, invalid_reason);
				}
				advance_arg();
				break;
			case 'c':
				/* column name */
				if (strlen(flag_arg) == 0) {
					snprintf(invalid_reason, 200, "-c requires an argument");
					return parse_print_usage(prog, invalid_reason);
				}
				ret->fields = realloc(ret->fields, ++ret->field_count * sizeof(struct field_spec));
				ret->fields[ret->field_count-1] = (struct field_spec) {-1, -1, flag_arg};
				advance_arg();
				break;
			case 'd':
				/* delim flag */
				if (strlen(flag_arg) != 1) {
					snprintf(invalid_reason, 200, "invalid length for delimiter: need 1 got %ld", strlen(flag_arg));
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
			case 'h': return parse_print_usage(prog, NULL);
			case 'v':
				  ret->verbose = true;
				  break;
			case 'r':
				  ret->skip_rows = 1;
				  break;
			default:
				snprintf(invalid_reason, 200, "unknown flag '%c'", arg[1]);
				return parse_print_usage(prog, invalid_reason);
			}

			arg = &arg[1];
		}
	break_upper_loop:
		i = i; /* noop */
	}

	/* set defaults for fields */
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

/* column matching helper functions ----------------------------------------- */

bool
check_column_match(char* fieldbuf, int32_t fieldbuf_pos, struct flag_info* flags, int32_t field_num) {
	int i;
	struct field_spec fs;

	for (i = 0; i < flags->field_count; i++) {
		fs = flags->fields[i];
		if (fs.col_name == NULL)
			continue;
		if (strncmp(fieldbuf, fs.col_name, fieldbuf_pos) == 0) {
			/* we add a new fieldspec for each field_num that matches. while this
			 * may seem inefficient, it is simple and it allows us to reset the "extra"
			 * fields when changing files. different files may have different ordering
			 * of columns, and we should respect that. */
			flags->fields = realloc(flags->fields, ++flags->field_count * sizeof(struct field_spec));
			flags->fields[flags->field_count-1] = (struct field_spec) {field_num, field_num, fs.col_name};
			return true;
		}
	}
	return false;
}

void
reset_extra_field_specs(struct flag_info* flags) {
	int32_t i;

	for (i = 0; i < flags->field_count; i++) {
		if (flags->fields[i].col_name != NULL && flags->fields[i].min >= 0) {
			/* this is the first extra field. delete from here. */
			flags->field_count = i;
		}
	}
}

/* main program ------------------------------------------------------------- */

/* determine whether a field should be printed based on the flags. */
bool
should_print_field(struct flag_info* flags, int32_t num, int32_t row_num) {
	int32_t i;
	struct field_spec curr;

	// Still have rows to skip
	if (row_num <= flags->skip_rows)
		return false;

	for (i = 0; i < flags->field_count; i++) {
		curr = flags->fields[i];
		if (num >= curr.min && num <= curr.max)
			return true;
	}

	return false;
}

#define BUF_SIZE 1 << 13

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
	int32_t row_num;
	bool in_quotes;
	char last_char = 0;
	char* fieldbuf;
	size_t fieldbuf_sz = BUF_SIZE;
	int32_t fieldbuf_pos = 0;
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
	fieldbuf = calloc(BUF_SIZE, 1);

	for (i = 0; i < flags->file_count; i++) {
		in_quotes = false;
		should_print = should_print_field(flags, 1, 1);
		read = 0;
		pos = 0;
		field_num = 1;
		row_num = 1;
		num_printed = 0;
		last_char = 0;
		if (i > 0) {
			/* reset fieldspecs coming from matching column names,
			 * as they will need to be rematched in this second file. */
			reset_extra_field_specs(flags);
		}

		verbose("opening file %s\n", flags->files[i]);

		file = fopen(flags->files[i], "rb");
		if (file == NULL) {
			fprintf(stderr, "could not open %s\n", flags->files[i]);
			return 1;
		}
#define addchar(x) \
	if (fieldbuf_pos+1 >= fieldbuf_sz) {\
		fieldbuf = realloc(fieldbuf, fieldbuf_sz * 2);\
		memset(&fieldbuf[fieldbuf_sz], 0, fieldbuf_sz);\
		fieldbuf_sz *= 2;\
	} \
	fieldbuf[fieldbuf_pos++] = x;\
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
				if (row_num == 1) {
					/* check whether fieldbuf == one of the field names in flags.
					 * if so, recalculate should_print as that might have changed */
					if (check_column_match(fieldbuf, fieldbuf_pos, flags, field_num))
						should_print = should_print_field(flags, field_num, row_num);
				}
				if (should_print) {
					if (num_printed > 0)
						fputs(flags->out_delim, stdout);
					fwrite(fieldbuf, sizeof(char), fieldbuf_pos, stdout);
					num_printed++;
				}
				fieldbuf_pos = 0;
				if (buf[pos] == '\n') {
					if (num_printed > 0)
						fputc('\n', stdout);
					field_num = 1;
					num_printed = 0;
					row_num++;
				} else {
					field_num++;
				}
				last_char = 0;
				should_print = should_print_field(flags, field_num, row_num);
			}
		}

		/* print last one in case we are missing a newline at the end of the
		 * file. notice we check fieldbuf_pos to account for empty lines (last line) */
		if (should_print && fieldbuf_pos != 0) {
			if (num_printed > 0)
				fputs(flags->out_delim, stdout);
			fwrite(fieldbuf, sizeof(char), fieldbuf_pos, stdout);
			num_printed++;
		}
		fieldbuf_pos = 0;

		if (num_printed != 0)
			fputc('\n', stdout);
		fclose(file);
	}

	return 0;
}
