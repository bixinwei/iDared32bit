/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */
//! Legacy peer sessions in offline mode. No peers are advertised or connected.

use crate::dyld::{ConstantExports, HostConstant};
use crate::frameworks::foundation::{ns_string, NSInteger, NSTimeInterval};
use crate::mem::{MutPtr, MutVoidPtr};
use crate::objc::{
    id, msg, msg_class, nil, objc_classes, release, ClassExports, HostObject, NSZonePtr,
};
use crate::Environment;
use std::collections::HashSet;

const GKSessionErrorDomain: &str = "GKSessionErrorDomain";
const GKSessionConnectionFailedError: NSInteger = 30505;
const GKSessionNotConnectedError: NSInteger = 30508;
const GKSessionCannotEnableError: NSInteger = 30509;

struct SessionHostObject {
    session_id: id,
    display_name: id,
    peer_id: id,
    mode: NSInteger,
    delegate: id, // Legacy assign property, not retained.
    disconnect_timeout: NSTimeInterval,
    enable_failed: bool,
    pending_connections: HashSet<String>,
}
impl HostObject for SessionHostObject {}

fn offline_error(env: &mut Environment, code: NSInteger) -> id {
    let domain = ns_string::get_static_str(env, GKSessionErrorDomain);
    let key = ns_string::get_static_str(env, "NSLocalizedDescription");
    let description = ns_string::get_static_str(
        env,
        "Peer-to-peer networking is unavailable in iDared32bit.",
    );
    let user_info: id = msg_class![env; NSDictionary dictionaryWithObject:description forKey:key];
    msg_class![env; NSError errorWithDomain:domain code:code userInfo:user_info]
}

fn fail_operation(env: &mut Environment, out_error: MutPtr<id>) -> bool {
    let error = offline_error(env, GKSessionNotConnectedError);
    if !out_error.is_null() {
        env.mem.write(out_error, error);
    }
    false
}

fn has_method(env: &Environment, object: id, name: &str) -> bool {
    object != nil
        && env
            .objc
            .lookup_selector(name)
            .is_some_and(|sel| env.objc.object_has_method(&env.mem, object, sel))
}

pub const CLASSES: ClassExports = objc_classes! {
(env, this, _cmd);

@implementation GKSession: NSObject

+ (id)allocWithZone:(NSZonePtr)_zone {
    let object = Box::new(SessionHostObject {
        session_id: nil, display_name: nil, peer_id: nil, mode: 2,
        delegate: nil, disconnect_timeout: 20.0, enable_failed: false,
        pending_connections: HashSet::new(),
    });
    env.objc.alloc_object(this, object, &mut env.mem)
}

- (id)init {
    msg![env; this initWithSessionID:nil displayName:nil sessionMode:2i32]
}

- (id)initWithSessionID:(id)session_id displayName:(id)display_name sessionMode:(NSInteger)mode {
    let session_id = if session_id == nil {
        let identifier = env.bundle.bundle_identifier().to_owned();
        ns_string::from_rust_string(env, identifier)
    } else {
        msg![env; session_id copy]
    };
    let display_name = if display_name == nil {
        ns_string::from_rust_string(env, "iDared32bit".to_owned())
    } else {
        msg![env; display_name copy]
    };
    let peer_id = ns_string::from_rust_string(env, format!("offline-{:08x}", this.to_bits()));
    let object = env.objc.borrow_mut::<SessionHostObject>(this);
    let old = (object.session_id, object.display_name, object.peer_id);
    object.session_id = session_id;
    object.display_name = display_name;
    object.peer_id = peer_id;
    object.mode = mode;
    release(env, old.0);
    release(env, old.1);
    release(env, old.2);
    log!("GKSession initialized in offline mode; single-player can continue.");
    this
}

- (id)sessionID { env.objc.borrow::<SessionHostObject>(this).session_id }
- (id)displayName { env.objc.borrow::<SessionHostObject>(this).display_name }
- (id)peerID { env.objc.borrow::<SessionHostObject>(this).peer_id }
- (NSInteger)sessionMode { env.objc.borrow::<SessionHostObject>(this).mode }
- (id)delegate { env.objc.borrow::<SessionHostObject>(this).delegate }
- (())setDelegate:(id)delegate { env.objc.borrow_mut::<SessionHostObject>(this).delegate = delegate; }
- (NSTimeInterval)disconnectTimeout { env.objc.borrow::<SessionHostObject>(this).disconnect_timeout }
- (())setDisconnectTimeout:(NSTimeInterval)timeout {
    env.objc.borrow_mut::<SessionHostObject>(this).disconnect_timeout = timeout;
}
- (bool)isAvailable { false }
- (())setAvailable:(bool)available {
    let object = env.objc.borrow_mut::<SessionHostObject>(this);
    if !available {
        object.enable_failed = false;
        return;
    }
    if object.enable_failed { return; }
    object.enable_failed = true;
    let sel = env.objc.lookup_selector("_touchHLE_sessionUnavailable").unwrap();
    () = msg![env; this performSelector:sel withObject:nil afterDelay:0.0f64];
}
- (())_touchHLE_sessionUnavailable {
    if !env.objc.borrow::<SessionHostObject>(this).enable_failed { return; }
    let delegate = env.objc.borrow::<SessionHostObject>(this).delegate;
    if has_method(env, delegate, "session:didFailWithError:") {
        let error = offline_error(env, GKSessionCannotEnableError);
        () = msg![env; delegate session:this didFailWithError:error];
    }
}
- (id)peersWithConnectionState:(NSInteger)_state { msg_class![env; NSArray array] }
- (id)displayNameForPeer:(id)peer {
    let local_peer = env.objc.borrow::<SessionHostObject>(this).peer_id;
    if peer != nil && msg![env; peer isEqual:local_peer] {
        env.objc.borrow::<SessionHostObject>(this).display_name
    } else { nil }
}
- (())setDataReceiveHandler:(id)_handler withContext:(MutVoidPtr)_context {
    // No connected peers exist, so there can be no incoming data callbacks.
}
- (())connectToPeer:(id)peer withTimeout:(NSTimeInterval)_timeout {
    if peer == nil { return; }
    let key = ns_string::to_rust_string(env, peer).into_owned();
    if !env.objc.borrow_mut::<SessionHostObject>(this).pending_connections.insert(key) { return; }
    let sel = env.objc.lookup_selector("_touchHLE_connectionFailed:").unwrap();
    () = msg![env; this performSelector:sel withObject:peer afterDelay:0.0f64];
}
- (())_touchHLE_connectionFailed:(id)peer {
    let key = ns_string::to_rust_string(env, peer).into_owned();
    if !env.objc.borrow_mut::<SessionHostObject>(this).pending_connections.remove(&key) { return; }
    let delegate = env.objc.borrow::<SessionHostObject>(this).delegate;
    if has_method(env, delegate, "session:connectionWithPeerFailed:withError:") {
        let error = offline_error(env, GKSessionConnectionFailedError);
        () = msg![env; delegate session:this connectionWithPeerFailed:peer withError:error];
    }
}
- (())cancelConnectToPeer:(id)peer {
    if peer == nil { return; }
    let key = ns_string::to_rust_string(env, peer).into_owned();
    env.objc.borrow_mut::<SessionHostObject>(this).pending_connections.remove(&key);
    let sel = env.objc.lookup_selector("_touchHLE_connectionFailed:").unwrap();
    () = msg_class![env; NSObject cancelPreviousPerformRequestsWithTarget:this selector:sel object:peer];
}
- (bool)acceptConnectionFromPeer:(id)_peer error:(MutPtr<id>)out_error { fail_operation(env, out_error) }
- (())denyConnectionFromPeer:(id)_peer {}
- (())disconnectPeerFromAllPeers:(id)peer { () = msg![env; this cancelConnectToPeer:peer]; }
- (())disconnectFromAllPeers {
    env.objc.borrow_mut::<SessionHostObject>(this).pending_connections.clear();
    () = msg_class![env; NSObject cancelPreviousPerformRequestsWithTarget:this];
}
- (bool)sendData:(id)_data toPeers:(id)_peers withDataMode:(NSInteger)_mode error:(MutPtr<id>)out_error {
    fail_operation(env, out_error)
}
- (bool)sendDataToAllPeers:(id)_data withDataMode:(NSInteger)_mode error:(MutPtr<id>)out_error {
    fail_operation(env, out_error)
}
- (())dealloc {
    let object = env.objc.borrow::<SessionHostObject>(this);
    let old = (object.session_id, object.display_name, object.peer_id);
    release(env, old.0);
    release(env, old.1);
    release(env, old.2);
    env.objc.dealloc_object(this, &mut env.mem);
}
@end

// Legacy voice chat is unavailable along with peer networking. Returning nil
// is deliberate: callers can message the service safely without fake success.
@implementation GKVoiceChatService: NSObject
+ (bool)isVoIPAllowed { false }
+ (id)sharedVoiceChatService { nil }
@end
};

pub const CONSTANTS: ConstantExports = &[(
    "_GKSessionErrorDomain",
    HostConstant::NSString(GKSessionErrorDomain),
)];
