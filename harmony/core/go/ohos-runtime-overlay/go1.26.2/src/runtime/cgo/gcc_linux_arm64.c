// Copyright 2015 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

#include <pthread.h>
#include <errno.h>
#include <string.h>
#include <signal.h>
#include <stdlib.h>
#include "libcgo.h"
#include "libcgo_unix.h"

static void *threadentry(void*);

void (*x_cgo_inittls)(void **tlsg, void **tlsbase) __attribute__((common));
static void (*setg_gcc)(void*);

static pthread_key_t cmfa_ohos_go_g_key;
static int cmfa_ohos_go_g_key_initialized;

static void
cmfa_ohos_prepare_g_key(void)
{
	int err = pthread_key_create(&cmfa_ohos_go_g_key, NULL);
	if (err != 0) {
		fatalf("pthread_key_create failed: %s", strerror(err));
	}
	cmfa_ohos_go_g_key_initialized = 1;
}

__attribute__((visibility("hidden")))
void *
x_cgo_ohos_load_g(void)
{
	if (!cmfa_ohos_go_g_key_initialized) {
		fatalf("Go g pthread key is not initialized");
	}
	return pthread_getspecific(cmfa_ohos_go_g_key);
}

__attribute__((visibility("hidden")))
void
x_cgo_ohos_save_g(void *g)
{
	int err;
	if (!cmfa_ohos_go_g_key_initialized) {
		fatalf("Go g pthread key is not initialized");
	}
	err = pthread_setspecific(cmfa_ohos_go_g_key, g);
	if (err != 0) {
		fatalf("pthread_setspecific failed: %s", strerror(err));
	}
}

void
_cgo_sys_thread_start(ThreadStart *ts)
{
	pthread_attr_t attr;
	sigset_t ign, oset;
	pthread_t p;
	size_t size;
	int err;

	sigfillset(&ign);
	pthread_sigmask(SIG_SETMASK, &ign, &oset);

	pthread_attr_init(&attr);
	pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
	pthread_attr_getstacksize(&attr, &size);
	// Leave stacklo=0 and set stackhi=size; mstart will do the rest.
	ts->g->stackhi = size;
	err = _cgo_try_pthread_create(&p, &attr, threadentry, ts);

	pthread_sigmask(SIG_SETMASK, &oset, nil);

	if (err != 0) {
		fatalf("pthread_create failed: %s", strerror(err));
	}
}

extern void crosscall1(void (*fn)(void), void (*setg_gcc)(void*), void *g);
static void*
threadentry(void *v)
{
	ThreadStart ts;

	ts = *(ThreadStart*)v;
	free(v);

	crosscall1(ts.fn, setg_gcc, (void*)ts.g);
	return nil;
}

void
x_cgo_init(G *g, void (*setg)(void*), void **tlsg, void **tlsbase)
{
	uintptr *pbounds;

	/* The memory sanitizer distributed with versions of clang
	   before 3.8 has a bug: if you call mmap before malloc, mmap
	   may return an address that is later overwritten by the msan
	   library.  Avoid this problem by forcing a call to malloc
	   here, before we ever call malloc.

	   This is only required for the memory sanitizer, so it's
	   unfortunate that we always run it.  It should be possible
	   to remove this when we no longer care about versions of
	   clang before 3.8.  The test for this is
	   misc/cgo/testsanitizers.

	   GCC works hard to eliminate a seemingly unnecessary call to
	   malloc, so we actually use the memory we allocate.  */

	cmfa_ohos_prepare_g_key();
	setg_gcc = setg;
	pbounds = (uintptr*)malloc(2 * sizeof(uintptr));
	if (pbounds == NULL) {
		fatalf("malloc failed: %s", strerror(errno));
	}
	_cgo_set_stacklo(g, pbounds);
	free(pbounds);

	if (x_cgo_inittls) {
		x_cgo_inittls(tlsg, tlsbase);
	}
}
