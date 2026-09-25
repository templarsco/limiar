pub mod config;
pub mod gpu_pv;
pub mod identity;
pub mod registry;
pub mod report;
pub mod runner;

#[cfg(windows)]
mod hcs;

#[cfg(windows)]
mod presentation;

#[cfg(windows)]
#[path = "windows.rs"]
pub mod platform;

#[cfg(not(windows))]
#[path = "unsupported.rs"]
pub mod platform;
