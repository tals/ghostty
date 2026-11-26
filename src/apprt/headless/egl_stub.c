// Stands in for libEGL.so.1 at link time, so a Linux ghostty-host links on
// any OS. The machine it runs on supplies the real library. These are
// EGL 1.5's core functions, which glad expects to be linked rather than
// loaded.
void eglBindAPI(void) {}
void eglBindTexImage(void) {}
void eglChooseConfig(void) {}
void eglClientWaitSync(void) {}
void eglCopyBuffers(void) {}
void eglCreateContext(void) {}
void eglCreateImage(void) {}
void eglCreatePbufferFromClientBuffer(void) {}
void eglCreatePbufferSurface(void) {}
void eglCreatePixmapSurface(void) {}
void eglCreatePlatformPixmapSurface(void) {}
void eglCreatePlatformWindowSurface(void) {}
void eglCreateSync(void) {}
void eglCreateWindowSurface(void) {}
void eglDestroyContext(void) {}
void eglDestroyImage(void) {}
void eglDestroySurface(void) {}
void eglDestroySync(void) {}
void eglGetConfigAttrib(void) {}
void eglGetConfigs(void) {}
void eglGetCurrentContext(void) {}
void eglGetCurrentDisplay(void) {}
void eglGetCurrentSurface(void) {}
void eglGetDisplay(void) {}
void eglGetError(void) {}
void eglGetPlatformDisplay(void) {}
void eglGetProcAddress(void) {}
void eglGetSyncAttrib(void) {}
void eglInitialize(void) {}
void eglMakeCurrent(void) {}
void eglQueryAPI(void) {}
void eglQueryContext(void) {}
void eglQueryString(void) {}
void eglQuerySurface(void) {}
void eglReleaseTexImage(void) {}
void eglReleaseThread(void) {}
void eglSurfaceAttrib(void) {}
void eglSwapBuffers(void) {}
void eglSwapInterval(void) {}
void eglTerminate(void) {}
void eglWaitClient(void) {}
void eglWaitGL(void) {}
void eglWaitNative(void) {}
void eglWaitSync(void) {}
