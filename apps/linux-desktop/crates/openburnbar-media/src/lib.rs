#[derive(Debug, Clone)]
pub struct MediaFrame<'a> {
    pub kind: u8,
    pub flags: u8,
    pub pts_ms: u64,
    pub payload: &'a [u8],
}
