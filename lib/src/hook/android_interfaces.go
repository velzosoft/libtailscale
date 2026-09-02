// Copyright (c) 2026 the libtailscale Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

//go:build android

// Added to the upstream libtailscale package by package:libtailscale's build
// hook through `go build -overlay`, for GOOS=android only. The upstream tree
// is not modified.
//
// Android 11 and later deny netlink RTM_GETLINK to apps, so Go's
// net.Interfaces() fails with "netlinkrib: permission denied" and tsnet cannot
// start (golang/go#40569). Bionic's getifaddrs(3) copes with that restriction,
// so interfaces are enumerated through it and handed to netmon, which is what
// the Tailscale Android app does through Java's NetworkInterface.
package main

/*
#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/types.h>
*/
import "C"

import (
	"fmt"
	"net"
	"os"
	"unsafe"

	"tailscale.com/net/netmon"
)

func init() {
	netmon.RegisterInterfaceGetter(getifaddrsInterfaces)
}

// tailscale_dart_setenv sets an environment variable in the Go runtime's copy
// of the environment (and, through os.Setenv, the C one). Go copies environ
// when the library loads, so a C setenv(3) made afterwards is invisible to
// tsnet; the Dart side uses this to give an Android app process the $HOME and
// $TMPDIR that tailscale's logpolicy requires. With overwrite == 0 an existing
// non-empty value is kept. Returns 0 on success, -1 on failure.
//
//export tailscale_dart_setenv
func tailscale_dart_setenv(name *C.char, value *C.char, overwrite C.int) C.int {
	n := C.GoString(name)
	if overwrite == 0 && os.Getenv(n) != "" {
		return 0
	}
	if err := os.Setenv(n, C.GoString(value)); err != nil {
		return -1
	}
	return 0
}

// getifaddrsInterfaces lists the interfaces and their addresses with
// getifaddrs(3). Hardware addresses are not available to apps and stay empty.
func getifaddrsInterfaces() ([]netmon.Interface, error) {
	var ifap *C.struct_ifaddrs
	if rc, err := C.getifaddrs(&ifap); rc != 0 {
		return nil, fmt.Errorf("getifaddrs: %w", err)
	}
	defer C.freeifaddrs(ifap)

	byName := map[string]*netmon.Interface{}
	var order []*netmon.Interface
	for ifa := ifap; ifa != nil; ifa = ifa.ifa_next {
		name := C.GoString(ifa.ifa_name)
		ni, ok := byName[name]
		if !ok {
			ni = &netmon.Interface{
				Interface: &net.Interface{
					Index: int(C.if_nametoindex(ifa.ifa_name)),
					Name:  name,
					Flags: linkFlags(uint32(ifa.ifa_flags)),
				},
				// Non-nil so Addrs() never falls back to netlink.
				AltAddrs: []net.Addr{},
			}
			byName[name] = ni
			order = append(order, ni)
		}
		if ifa.ifa_addr == nil {
			continue
		}
		switch int(ifa.ifa_addr.sa_family) {
		case C.AF_INET:
			sa := (*C.struct_sockaddr_in)(unsafe.Pointer(ifa.ifa_addr))
			ip := net.IP(C.GoBytes(unsafe.Pointer(&sa.sin_addr), 4))
			mask := net.CIDRMask(32, 32)
			if ifa.ifa_netmask != nil {
				m := (*C.struct_sockaddr_in)(unsafe.Pointer(ifa.ifa_netmask))
				mask = net.IPMask(C.GoBytes(unsafe.Pointer(&m.sin_addr), 4))
			}
			ni.AltAddrs = append(ni.AltAddrs, &net.IPNet{IP: ip, Mask: mask})
		case C.AF_INET6:
			sa := (*C.struct_sockaddr_in6)(unsafe.Pointer(ifa.ifa_addr))
			ip := net.IP(C.GoBytes(unsafe.Pointer(&sa.sin6_addr), 16))
			mask := net.CIDRMask(128, 128)
			if ifa.ifa_netmask != nil {
				m := (*C.struct_sockaddr_in6)(unsafe.Pointer(ifa.ifa_netmask))
				mask = net.IPMask(C.GoBytes(unsafe.Pointer(&m.sin6_addr), 16))
			}
			ni.AltAddrs = append(ni.AltAddrs, &net.IPNet{IP: ip, Mask: mask})
		}
	}
	out := make([]netmon.Interface, 0, len(order))
	for _, ni := range order {
		out = append(out, *ni)
	}
	return out, nil
}

// linkFlags maps SIOCGIFFLAGS bits to net.Flags like the standard library.
func linkFlags(raw uint32) net.Flags {
	var f net.Flags
	if raw&C.IFF_UP != 0 {
		f |= net.FlagUp
	}
	if raw&C.IFF_BROADCAST != 0 {
		f |= net.FlagBroadcast
	}
	if raw&C.IFF_LOOPBACK != 0 {
		f |= net.FlagLoopback
	}
	if raw&C.IFF_POINTOPOINT != 0 {
		f |= net.FlagPointToPoint
	}
	if raw&C.IFF_MULTICAST != 0 {
		f |= net.FlagMulticast
	}
	if raw&C.IFF_RUNNING != 0 {
		f |= net.FlagRunning
	}
	return f
}
