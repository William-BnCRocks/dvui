const std = @import("std");
const dvui = @import("../dvui.zig");

const Event = dvui.Event;
const Options = dvui.Options;
const Point = dvui.Point;
const Rect = dvui.Rect;
const RectScale = dvui.RectScale;
const ScrollInfo = dvui.ScrollInfo;
const Size = dvui.Size;
const Widget = dvui.Widget;
const WidgetData = dvui.WidgetData;

const ScrollContainerWidget = @This();

pub var defaults: Options = .{
    .name = "ScrollContainer",
    // most of the time ScrollContainer is used inside ScrollArea which
    // overrides these
    .background = true,
    .min_size_content = .{ .w = 5, .h = 5 },
};

wd: WidgetData = undefined,

si: *ScrollInfo = undefined,

// si.viewport.x/y might be updated in the middle of a frame, this prevents
// those visual artifacts
frame_viewport: Point = Point{},

process_events: bool = true,
prevClip: Rect = Rect{},

nextVirtualSize: Size = Size{},
expand_to_fit: bool = false,
next_widget_ypos: f32 = 0, // goes from 0 to viritualSize.h

inject_capture_id: ?u32 = null,
seen_scroll_drag: bool = false,

finger_down: bool = false,

pub fn init(src: std.builtin.SourceLocation, io_scroll_info: *ScrollInfo, opts: Options) ScrollContainerWidget {
    var self = ScrollContainerWidget{};
    const options = defaults.override(opts);

    self.wd = WidgetData.init(src, .{}, options);

    self.si = io_scroll_info;
    self.finger_down = dvui.dataGet(null, self.wd.id, "_finger_down", bool) orelse false;

    const crect = self.wd.contentRect();
    self.si.viewport.w = crect.w;
    self.si.viewport.h = crect.h;

    self.next_widget_ypos = 0;
    return self;
}

pub fn install(self: *ScrollContainerWidget) !void {
    try self.wd.register();

    // user code might have changed our rect
    const crect = self.wd.contentRect();
    self.si.viewport.w = crect.w;
    self.si.viewport.h = crect.h;

    switch (self.si.horizontal) {
        .none => self.si.virtual_size.w = crect.w,
        .auto => {},
        .given => {},
    }
    switch (self.si.vertical) {
        .none => self.si.virtual_size.h = crect.h,
        .auto => {},
        .given => {},
    }

    try self.wd.borderAndBackground(.{});

    self.prevClip = dvui.clip(self.wd.contentRectScale().r);

    self.frame_viewport = self.si.viewport.topLeft();

    dvui.parentSet(self.widget());
}

pub fn matchEvent(self: *ScrollContainerWidget, e: *Event) bool {
    // track finger press/release even if it doesn't happen in our rect
    if (e.evt == .mouse and e.evt.mouse.action == .press and e.evt.mouse.button.touch()) {
        self.finger_down = true;
    } else if (e.evt == .mouse and e.evt.mouse.action == .release and e.evt.mouse.button.touch()) {
        self.finger_down = false;
    }

    return dvui.eventMatch(e, .{ .id = self.data().id, .r = self.data().borderRectScale().r });
}

pub fn processEvents(self: *ScrollContainerWidget) void {
    const evts = dvui.events();
    for (evts) |*e| {
        if (!self.matchEvent(e))
            continue;

        self.processEvent(e, false);
    }

    // might have changed from events
    self.frame_viewport = self.si.viewport.topLeft();
}

pub fn processVelocity(self: *ScrollContainerWidget) void {
    if (!self.finger_down) {
        {
            const damping = 0.0001 + @min(1.0, @abs(self.si.velocity.x) / 50.0) * (0.7 - 0.0001);
            self.si.velocity.x *= @exp(@log(damping) * dvui.secondsSinceLastFrame());
            if (@abs(self.si.velocity.x) > 1) {
                //std.debug.print("vel x {d}\n", .{self.si.velocity.x});
                self.si.viewport.x += self.si.velocity.x * 50 * dvui.secondsSinceLastFrame();
                dvui.refresh(null, @src(), self.wd.id);
            } else {
                self.si.velocity.x = 0;
            }
        }

        {
            const damping = 0.0001 + @min(1.0, @abs(self.si.velocity.y) / 50.0) * (0.7 - 0.0001);
            self.si.velocity.y *= @exp(@log(damping) * dvui.secondsSinceLastFrame());
            if (@abs(self.si.velocity.y) > 1) {
                //std.debug.print("vel y {d}\n", .{self.si.velocity.y});
                self.si.viewport.y += self.si.velocity.y * 50 * dvui.secondsSinceLastFrame();
                dvui.refresh(null, @src(), self.wd.id);
            } else {
                self.si.velocity.y = 0;
            }
        }
    }

    // damping is only for touch currently
    // exponential decay: v *= damping^secs_since
    // tweak the damping so we brake harder as the velocity slows down
    {
        const max_scroll = self.si.scroll_max(.horizontal);
        if (self.si.viewport.x < 0) {
            self.si.velocity.x = 0;
            self.si.viewport.x = @min(0, @max(-20, self.si.viewport.x + 250 * dvui.secondsSinceLastFrame()));
            if (self.si.viewport.x < 0) {
                dvui.refresh(null, @src(), self.wd.id);
            }
        } else if (self.si.viewport.x > max_scroll) {
            self.si.velocity.x = 0;
            self.si.viewport.x = @max(max_scroll, @min(max_scroll + 20, self.si.viewport.x - 250 * dvui.secondsSinceLastFrame()));
            if (self.si.viewport.x > max_scroll) {
                dvui.refresh(null, @src(), self.wd.id);
            }
        }
    }

    {
        const max_scroll = self.si.scroll_max(.vertical);

        if (self.si.viewport.y < 0) {
            self.si.velocity.y = 0;
            self.si.viewport.y = @min(0, @max(-20, self.si.viewport.y + 250 * dvui.secondsSinceLastFrame()));
            if (self.si.viewport.y < 0) {
                dvui.refresh(null, @src(), self.wd.id);
            }
        } else if (self.si.viewport.y > max_scroll) {
            self.si.velocity.y = 0;
            self.si.viewport.y = @max(max_scroll, @min(max_scroll + 20, self.si.viewport.y - 250 * dvui.secondsSinceLastFrame()));
            if (self.si.viewport.y > max_scroll) {
                dvui.refresh(null, @src(), self.wd.id);
            }
        }
    }

    // might have changed from events
    self.frame_viewport = self.si.viewport.topLeft();
}

pub fn widget(self: *ScrollContainerWidget) Widget {
    return Widget.init(self, data, rectFor, screenRectScale, minSizeForChild, processEvent);
}

pub fn data(self: *ScrollContainerWidget) *WidgetData {
    return &self.wd;
}

pub fn rectFor(self: *ScrollContainerWidget, id: u32, min_size: Size, e: Options.Expand, g: Options.Gravity) Rect {
    const y = self.next_widget_ypos;

    // Our virtual size might be smaller than our viewport, and the child could
    // be expanded, so we want them to take all available space.
    const maxh = @max(self.si.virtual_size.h, self.si.viewport.h);
    const maxw = @max(self.si.virtual_size.w, self.si.viewport.w);

    const h = maxh - y;
    const rect = Rect{ .x = 0, .y = y, .w = maxw, .h = h };
    const ret = dvui.placeIn(rect, dvui.minSize(id, min_size), e, g);
    self.next_widget_ypos = (ret.y + ret.h);
    return ret;
}

pub fn screenRectScale(self: *ScrollContainerWidget, rect: Rect) RectScale {
    var r = rect;
    r.y -= self.frame_viewport.y;
    r.x -= self.frame_viewport.x;

    return self.wd.contentRectScale().rectToRectScale(r);
}

pub fn minSizeForChild(self: *ScrollContainerWidget, s: Size) void {
    self.nextVirtualSize.h += s.h;
    self.nextVirtualSize.w = @max(self.nextVirtualSize.w, s.w);
    const padded = self.wd.padSize(self.nextVirtualSize);
    switch (self.si.vertical) {
        .none => self.wd.min_size.h = padded.h,
        .auto => {
            if (self.expand_to_fit) {
                self.wd.min_size.h = padded.h;
            }
        },
        .given => {},
    }
    switch (self.si.horizontal) {
        .none => self.wd.min_size.w = padded.w,
        .auto => {
            if (self.expand_to_fit) {
                self.wd.min_size.w = padded.w;
            }
        },
        .given => {},
    }
}

pub fn processEvent(self: *ScrollContainerWidget, e: *Event, bubbling: bool) void {
    switch (e.evt) {
        .mouse => |me| {
            // for finger down we let the event go through but stop any velocity scrolling
            if (me.action == .press and me.button.touch()) {
                // stop any current scrolling
                if (self.si.velocity.x != 0 or self.si.velocity.y != 0) {
                    // if we were scrolling, then eat the finger press so it
                    // doesn't do anything other than stop the scroll
                    e.handled = true;

                    self.si.velocity.x = 0;
                    self.si.velocity.y = 0;
                }
            }
        },
        .key => |ke| {
            if (bubbling or (self.wd.id == dvui.focusedWidgetId())) {
                if (ke.code == .up and (ke.action == .down or ke.action == .repeat)) {
                    e.handled = true;
                    if (self.si.vertical != .none) {
                        self.si.viewport.y -= 10;
                        self.si.viewport.y = dvui.math.clamp(self.si.viewport.y, 0, self.si.scroll_max(.vertical));
                    }
                    dvui.refresh(null, @src(), self.wd.id);
                } else if (ke.code == .down and (ke.action == .down or ke.action == .repeat)) {
                    e.handled = true;
                    if (self.si.vertical != .none) {
                        self.si.viewport.y += 10;
                        self.si.viewport.y = dvui.math.clamp(self.si.viewport.y, 0, self.si.scroll_max(.vertical));
                    }
                    dvui.refresh(null, @src(), self.wd.id);
                } else if (ke.code == .left and (ke.action == .down or ke.action == .repeat)) {
                    e.handled = true;
                    if (self.si.horizontal != .none) {
                        self.si.viewport.x -= 10;
                        self.si.viewport.x = dvui.math.clamp(self.si.viewport.x, 0, self.si.scroll_max(.horizontal));
                    }
                    dvui.refresh(null, @src(), self.wd.id);
                } else if (ke.code == .right and (ke.action == .down or ke.action == .repeat)) {
                    e.handled = true;
                    if (self.si.horizontal != .none) {
                        self.si.viewport.x += 10;
                        self.si.viewport.x = dvui.math.clamp(self.si.viewport.x, 0, self.si.scroll_max(.horizontal));
                    }
                    dvui.refresh(null, @src(), self.wd.id);
                } else if (ke.code == .page_up and (ke.action == .down or ke.action == .repeat)) {
                    e.handled = true;
                    self.si.scrollPageUp(.vertical);
                    dvui.refresh(null, @src(), self.wd.id);
                } else if (ke.code == .page_down and (ke.action == .down or ke.action == .repeat)) {
                    e.handled = true;
                    self.si.scrollPageDown(.vertical);
                    dvui.refresh(null, @src(), self.wd.id);
                }
            }
        },
        .scroll_drag => |sd| {
            e.handled = true;
            const rs = self.wd.contentRectScale();
            var scrolly: f32 = 0;
            if (sd.mouse_pt.y <= rs.r.y and // want to scroll up
                sd.screen_rect.y < rs.r.y and // scrolling would show more of child
                self.si.viewport.y > 0) // can scroll up
            {
                scrolly = if (!self.seen_scroll_drag) -200 * dvui.secondsSinceLastFrame() else -5;
            }

            if (sd.mouse_pt.y >= (rs.r.y + rs.r.h) and
                (sd.screen_rect.y + sd.screen_rect.h) > (rs.r.y + rs.r.h) and
                self.si.viewport.y < self.si.scroll_max(.vertical))
            {
                scrolly = if (!self.seen_scroll_drag) 200 * dvui.secondsSinceLastFrame() else 5;
            }

            var scrollx: f32 = 0;
            if (sd.mouse_pt.x <= rs.r.x and // want to scroll left
                sd.screen_rect.x < rs.r.x and // scrolling would show more of child
                self.si.viewport.x > 0) // can scroll left
            {
                scrollx = if (!self.seen_scroll_drag) -200 * dvui.secondsSinceLastFrame() else -5;
            }

            if (sd.mouse_pt.x >= (rs.r.x + rs.r.w) and
                (sd.screen_rect.x + sd.screen_rect.w) > (rs.r.x + rs.r.w) and
                self.si.viewport.x < self.si.scroll_max(.horizontal))
            {
                scrollx = if (!self.seen_scroll_drag) 200 * dvui.secondsSinceLastFrame() else 5;
            }

            if (scrolly != 0 or scrollx != 0) {
                if (scrolly != 0) {
                    self.si.viewport.y = @max(0.0, @min(self.si.scroll_max(.vertical), self.si.viewport.y + scrolly));
                }
                if (scrollx != 0) {
                    self.si.viewport.x = @max(0.0, @min(self.si.scroll_max(.horizontal), self.si.viewport.x + scrollx));
                }

                dvui.refresh(null, @src(), self.wd.id);

                // if we are scrolling, then we need a motion event next
                // frame so that the child widget can adjust selection
                self.inject_capture_id = sd.capture_id;
            }

            self.seen_scroll_drag = true;
        },
        .scroll_to => |st| {
            e.handled = true;
            const rs = self.wd.contentRectScale();

            const ypx = @max(0.0, rs.r.y - st.screen_rect.y);
            if (ypx > 0) {
                self.si.viewport.y = self.si.viewport.y - (ypx / rs.s);
                if (!st.over_scroll) {
                    self.si.viewport.y = @max(0.0, @min(self.si.scroll_max(.vertical), self.si.viewport.y));
                }
                dvui.refresh(null, @src(), self.wd.id);
            }

            const ypx2 = @max(0.0, (st.screen_rect.y + st.screen_rect.h) - (rs.r.y + rs.r.h));
            if (ypx2 > 0) {
                self.si.viewport.y = self.si.viewport.y + (ypx2 / rs.s);
                if (!st.over_scroll) {
                    self.si.viewport.y = @max(0.0, @min(self.si.scroll_max(.vertical), self.si.viewport.y));
                }
                dvui.refresh(null, @src(), self.wd.id);
            }

            const xpx = @max(0.0, rs.r.x - st.screen_rect.x);
            if (xpx > 0) {
                self.si.viewport.x = self.si.viewport.x - (xpx / rs.s);
                if (!st.over_scroll) {
                    self.si.viewport.x = @max(0.0, @min(self.si.scroll_max(.horizontal), self.si.viewport.x));
                }
                dvui.refresh(null, @src(), self.wd.id);
            }

            const xpx2 = @max(0.0, (st.screen_rect.x + st.screen_rect.w) - (rs.r.x + rs.r.w));
            if (xpx2 > 0) {
                self.si.viewport.x = self.si.viewport.x + (xpx2 / rs.s);
                if (!st.over_scroll) {
                    self.si.viewport.x = @max(0.0, @min(self.si.scroll_max(.horizontal), self.si.viewport.x));
                }
                dvui.refresh(null, @src(), self.wd.id);
            }
        },
        .scroll_propogate => |sp| {
            self.processMotionScrollEvent(e, sp.motion);
        },
        else => {},
    }

    if (e.bubbleable()) {
        self.wd.parent.processEvent(e, true);
    }
}

pub fn processMotionScrollEvent(self: *ScrollContainerWidget, e: *dvui.Event, motion: dvui.Point) void {
    e.handled = true;

    const rs = self.wd.borderRectScale();

    // Whether to propogate out to any containing scroll
    // containers. Propogate unless we did the whole scroll
    // in the main direction of movement.
    //
    // This helps prevent spurious propogation from a text
    // entry box where you are trying to scroll vertically
    // but the motion event has a small amount of
    // horizontal.
    var propogate: bool = true;

    if (self.si.vertical != .none) {
        self.si.viewport.y -= motion.y / rs.s;
        self.si.velocity.y = -motion.y / rs.s;
        dvui.refresh(null, @src(), self.wd.id);
        if (@abs(motion.y) > @abs(motion.x) and self.si.viewport.y >= 0 and self.si.viewport.y <= self.si.scroll_max(.vertical)) {
            propogate = false;
        }
    }
    if (self.si.horizontal != .none) {
        self.si.viewport.x -= motion.x / rs.s;
        self.si.velocity.x = -motion.x / rs.s;
        dvui.refresh(null, @src(), self.wd.id);
        if (@abs(motion.x) > @abs(motion.y) and self.si.viewport.x >= 0 and self.si.viewport.x <= self.si.scroll_max(.horizontal)) {
            propogate = false;
        }
    }

    if (propogate) {
        var scrollprop = Event{ .evt = .{ .scroll_propogate = .{ .motion = motion } } };
        self.wd.parent.processEvent(&scrollprop, true);
    }
}

pub fn processEventsAfter(self: *ScrollContainerWidget) void {
    const rs = self.wd.borderRectScale();
    const evts = dvui.events();
    for (evts) |*e| {
        if (!dvui.eventMatch(e, .{ .id = self.wd.id, .r = rs.r }))
            continue;

        switch (e.evt) {
            .mouse => |me| {
                if (me.action == .focus) {
                    e.handled = true;
                    // focus so that we can receive keyboard input
                    dvui.focusWidget(self.wd.id, null, e.num);
                } else if (me.action == .wheel_y) {
                    // scroll vertically if we can, otherwise try horizontal
                    if (self.si.vertical != .none) {
                        if ((me.data.wheel_y > 0 and self.si.viewport.y <= 0) or (me.data.wheel_y < 0 and self.si.viewport.y >= self.si.scroll_max(.vertical))) {
                            // propogate the scroll event because we are already maxxed out
                        } else {
                            e.handled = true;
                            self.si.viewport.y -= me.data.wheel_y;
                            self.si.viewport.y = dvui.math.clamp(self.si.viewport.y, 0, self.si.scroll_max(.vertical));
                            dvui.refresh(null, @src(), self.wd.id);
                        }
                    } else if (self.si.horizontal != .none) {
                        if ((me.data.wheel_y > 0 and self.si.viewport.x <= 0) or (me.data.wheel_y < 0 and self.si.viewport.x >= self.si.scroll_max(.horizontal))) {
                            // propogate the scroll event because we are already maxxed out
                        } else {
                            e.handled = true;
                            self.si.viewport.x -= me.data.wheel_y;
                            self.si.viewport.x = dvui.math.clamp(self.si.viewport.x, 0, self.si.scroll_max(.horizontal));
                            dvui.refresh(null, @src(), self.wd.id);
                        }
                    }
                } else if (me.action == .press and me.button.touch()) {
                    // don't let this event go through to floating window
                    // which would capture the mouse preventing scrolling
                    e.handled = true;
                    dvui.captureMouse(self.wd.id);
                } else if (me.action == .release and dvui.captured(self.wd.id)) {
                    e.handled = true;
                    dvui.captureMouse(null);
                } else if (me.action == .motion and me.button.touch()) {
                    // Need to capture here because it's common for the touch
                    // down to happen on top of a different widget.  Example is
                    // a touch down on a button, which captures.  Then when the
                    // drag starts the button gives up capture, so we get here,
                    // never having seen the touch down.
                    dvui.captureMouse(self.wd.id);

                    self.processMotionScrollEvent(e, me.data.motion);
                }
            },
            else => {},
        }
    }
}

pub fn deinit(self: *ScrollContainerWidget) void {
    if (self.process_events) {
        self.processEventsAfter();
    }

    dvui.dataSet(null, self.wd.id, "_finger_down", self.finger_down);

    if (self.inject_capture_id) |ci| {
        // Only do this if the widget that sent the scroll_drag event still has
        // mouse capture at this point.  Mouse could have moved, generated a
        // scroll_drag, then released - in that case we don't want to inject a
        // motion event next frame.
        if (ci == dvui.captureMouseId()) {
            // inject a mouse motion event into next frame
            dvui.currentWindow().inject_motion_event = true;
        }
    }

    dvui.clipSet(self.prevClip);

    switch (self.si.horizontal) {
        .none => {},
        .auto => {
            if (self.nextVirtualSize.w != self.si.virtual_size.w) {
                self.si.virtual_size.w = self.nextVirtualSize.w;
                dvui.refresh(null, @src(), self.wd.id);
            }
        },
        .given => {},
    }

    switch (self.si.vertical) {
        .none => {},
        .auto => {
            if (self.nextVirtualSize.h != self.si.virtual_size.h) {
                self.si.virtual_size.h = self.nextVirtualSize.h;
                dvui.refresh(null, @src(), self.wd.id);
            }
        },
        .given => {},
    }

    self.wd.minSizeSetAndRefresh();
    self.wd.minSizeReportToParent();
    dvui.parentReset(self.wd.id, self.wd.parent);
}
