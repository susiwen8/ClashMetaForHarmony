#ifndef CMFA_TEST_SHIM_NAPI_NATIVE_API_H
#define CMFA_TEST_SHIM_NAPI_NATIVE_API_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define NAPI_AUTO_LENGTH ((size_t)-1)

typedef struct napi_env__ *napi_env;
typedef struct napi_value__ *napi_value;
typedef struct napi_ref__ *napi_ref;
typedef struct napi_deferred__ *napi_deferred;
typedef struct napi_callback_info__ *napi_callback_info;
typedef struct napi_threadsafe_function__ *napi_threadsafe_function;
typedef struct napi_async_work__ *napi_async_work;

typedef enum {
  napi_ok = 0,
  napi_invalid_arg = 1,
  napi_object_expected = 2,
  napi_string_expected = 3,
  napi_name_expected = 4,
  napi_function_expected = 5,
  napi_number_expected = 6,
  napi_boolean_expected = 7,
  napi_array_expected = 8,
  napi_arraybuffer_expected = 9,
  napi_generic_failure = 10,
  napi_pending_exception = 11,
  napi_cancelled = 12,
  napi_closing = 13
} napi_status;

typedef enum {
  napi_undefined = 0,
  napi_null = 1,
  napi_boolean = 2,
  napi_number = 3,
  napi_string = 4,
  napi_symbol = 5,
  napi_object = 6,
  napi_function = 7,
  napi_external = 8,
  napi_bigint = 9
} napi_valuetype;

typedef enum {
  napi_default = 0
} napi_property_attributes;

typedef enum {
  napi_key_include_prototypes = 0,
  napi_key_own_only = 1
} napi_key_collection_mode;

typedef enum {
  napi_key_all_properties = 0,
  napi_key_writable = 1,
  napi_key_enumerable = 1 << 1,
  napi_key_configurable = 1 << 2,
  napi_key_skip_strings = 1 << 3,
  napi_key_skip_symbols = 1 << 4
} napi_key_filter;

typedef enum {
  napi_key_keep_numbers = 0,
  napi_key_numbers_to_strings = 1
} napi_key_conversion;

typedef enum {
  napi_tsfn_release = 0,
  napi_tsfn_abort = 1
} napi_threadsafe_function_release_mode;

typedef enum {
  napi_tsfn_nonblocking = 0,
  napi_tsfn_blocking = 1
} napi_threadsafe_function_call_mode;

typedef napi_value (*napi_callback)(napi_env env, napi_callback_info info);
typedef void (*napi_finalize)(napi_env env, void *finalize_data, void *finalize_hint);
typedef void (*napi_threadsafe_function_call_js)(napi_env env, napi_value js_callback, void *context, void *data);
typedef void (*napi_async_execute_callback)(napi_env env, void *data);
typedef void (*napi_async_complete_callback)(napi_env env, napi_status status, void *data);

typedef struct {
  const char *utf8name;
  void *name;
  napi_callback method;
  void *getter;
  void *setter;
  napi_value value;
  napi_property_attributes attributes;
  void *data;
} napi_property_descriptor;

napi_status napi_get_cb_info(napi_env env,
                             napi_callback_info info,
                             size_t *argc,
                             napi_value *argv,
                             napi_value *this_arg,
                             void **data);
napi_status napi_typeof(napi_env env, napi_value value, napi_valuetype *result);
napi_status napi_create_string_utf8(napi_env env, const char *str, size_t length, napi_value *result);
napi_status napi_get_value_string_utf8(napi_env env, napi_value value, char *buf, size_t bufsize, size_t *result);
napi_status napi_create_object(napi_env env, napi_value *result);
napi_status napi_create_array_with_length(napi_env env, size_t length, napi_value *result);
napi_status napi_set_named_property(napi_env env, napi_value object, const char *utf8name, napi_value value);
napi_status napi_get_named_property(napi_env env, napi_value object, const char *utf8name, napi_value *result);
napi_status napi_set_element(napi_env env, napi_value object, uint32_t index, napi_value value);
napi_status napi_get_element(napi_env env, napi_value object, uint32_t index, napi_value *result);
napi_status napi_get_array_length(napi_env env, napi_value value, uint32_t *result);
napi_status napi_is_array(napi_env env, napi_value value, bool *result);
napi_status napi_get_property_names(napi_env env, napi_value object, napi_value *result);
napi_status napi_get_all_property_names(napi_env env,
                                        napi_value object,
                                        napi_key_collection_mode key_mode,
                                        napi_key_filter key_filter,
                                        napi_key_conversion key_conversion,
                                        napi_value *result);
napi_status napi_create_uint32(napi_env env, uint32_t value, napi_value *result);
napi_status napi_create_int32(napi_env env, int32_t value, napi_value *result);
napi_status napi_create_int64(napi_env env, int64_t value, napi_value *result);
napi_status napi_get_value_int64(napi_env env, napi_value value, int64_t *result);
napi_status napi_get_value_double(napi_env env, napi_value value, double *result);
napi_status napi_get_value_bool(napi_env env, napi_value value, bool *result);
napi_status napi_get_boolean(napi_env env, bool value, napi_value *result);
napi_status napi_get_null(napi_env env, napi_value *result);
napi_status napi_get_undefined(napi_env env, napi_value *result);
napi_status napi_get_global(napi_env env, napi_value *result);
napi_status napi_get_prototype(napi_env env, napi_value object, napi_value *result);
napi_status napi_strict_equals(napi_env env, napi_value lhs, napi_value rhs, bool *result);
napi_status napi_create_error(napi_env env, napi_value code, napi_value msg, napi_value *result);
napi_status napi_throw(napi_env env, napi_value error);
napi_status napi_throw_error(napi_env env, const char *code, const char *msg);
napi_status napi_create_promise(napi_env env, napi_deferred *deferred, napi_value *promise);
napi_status napi_resolve_deferred(napi_env env, napi_deferred deferred, napi_value resolution);
napi_status napi_reject_deferred(napi_env env, napi_deferred deferred, napi_value rejection);
napi_status napi_is_arraybuffer(napi_env env, napi_value value, bool *result);
napi_status napi_get_arraybuffer_info(napi_env env, napi_value value, void **data, size_t *byte_length);
napi_status napi_create_async_work(napi_env env,
                                   napi_value async_resource,
                                   napi_value async_resource_name,
                                   napi_async_execute_callback execute,
                                   napi_async_complete_callback complete,
                                   void *data,
                                   napi_async_work *result);
napi_status napi_queue_async_work(napi_env env, napi_async_work work);
napi_status napi_delete_async_work(napi_env env, napi_async_work work);
napi_status napi_define_properties(napi_env env, napi_value object, size_t count, const napi_property_descriptor *properties);
napi_status napi_create_reference(napi_env env, napi_value value, uint32_t initial_refcount, napi_ref *result);
napi_status napi_get_reference_value(napi_env env, napi_ref ref, napi_value *result);
napi_status napi_delete_reference(napi_env env, napi_ref ref);
napi_status napi_call_function(napi_env env,
                               napi_value recv,
                               napi_value func,
                               size_t argc,
                               const napi_value *argv,
                               napi_value *result);
napi_status napi_create_threadsafe_function(napi_env env,
                                            napi_value func,
                                            napi_value async_resource,
                                            napi_value async_resource_name,
                                            size_t max_queue_size,
                                            size_t initial_thread_count,
                                            void *thread_finalize_data,
                                            napi_finalize thread_finalize_cb,
                                            void *context,
                                            napi_threadsafe_function_call_js call_js_cb,
                                            napi_threadsafe_function *result);
napi_status napi_call_threadsafe_function(napi_threadsafe_function func,
                                          void *data,
                                          napi_threadsafe_function_call_mode mode);
napi_status napi_release_threadsafe_function(napi_threadsafe_function func,
                                             napi_threadsafe_function_release_mode mode);

#ifdef __cplusplus
}
#endif

#endif
