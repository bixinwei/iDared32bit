/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */
//! Host app lifecycle bridge. The host (iOS) reports whether the app is in the
//! foreground, and the guest loop pauses the CPU and audio while it isn't.

#[cfg(target_os = "ios")]
pub mod native {
    use std::sync::OnceLock;

    type ActivityFn = unsafe extern "C" fn() -> i32;
    type WaitFn = unsafe extern "C" fn();
    static ACTIVITY: OnceLock<ActivityFn> = OnceLock::new();
    static WAIT: OnceLock<WaitFn> = OnceLock::new();

    #[no_mangle]
    pub extern "C" fn idared_set_host_activity(activity: ActivityFn, wait: WaitFn) {
        let _ = ACTIVITY.set(activity);
        let _ = WAIT.set(wait);
    }

    /// 0 = active, 1 = inactive, 2 = terminating.
    pub fn host_activity() -> i32 {
        ACTIVITY.get().map_or(0, |activity| unsafe { activity() })
    }

    pub fn wait_for_activity() {
        if let Some(wait) = WAIT.get() {
            unsafe { wait() };
        }
    }
}