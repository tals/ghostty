// A small JSON reader for request bodies, and string escaping for replies.
#pragma once
#include <stdbool.h>
#include <stddef.h>

typedef enum { J_NULL, J_BOOL, J_NUM, J_STR, J_ARR, J_OBJ } jtype;

typedef struct jval {
  jtype type;
  bool boolean;
  double number;
  char *str;  // J_STR: decoded UTF-8, NUL-terminated
  size_t len;
  char *key;  // set on members of a J_OBJ
  struct jval *child;  // first element or member
  struct jval *next;
} jval;

// Returns NULL and sets *err on malformed input.
jval *json_parse(const char *text, size_t len, const char **err);
void json_free(jval *v);
jval *json_get(const jval *obj, const char *key);
const char *json_str(const jval *obj, const char *key);  // NULL unless a string
bool json_num(const jval *obj, const char *key, double *out);
bool json_bool(const jval *obj, const char *key, bool fallback);

// Appends s as a quoted JSON string to buf (capacity cap, current length *used).
void json_escape(char *buf, size_t cap, size_t *used, const char *s);
