//
//  WebManifest.swift
//  DropPortalCore
//
//  A minimal web app manifest so "Add to Home screen" looks right on Android.
//  Static data, served without the token. No start_url: the browser then keeps
//  the address that was open, with the pairing code in it.
//

import Foundation

enum WebManifest {
    static let path = "/manifest.webmanifest"
    static let json = Data("""
    {"name":"Drop Portal","short_name":"Drop Portal","display":"standalone","background_color":"#0b0b0f","theme_color":"#0b0b0f","icons":[{"src":"/apple-touch-icon.png","sizes":"180x180","type":"image/png","purpose":"any"}]}
    """.utf8)
}
