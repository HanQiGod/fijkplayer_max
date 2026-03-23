//MIT License
//
//Copyright (c) [2019] [Befovy]
//
//Permission is hereby granted, free of charge, to any person obtaining a copy
//of this software and associated documentation files (the "Software"), to deal
//in the Software without restriction, including without limitation the rights
//to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//copies of the Software, and to permit persons to whom the Software is
//furnished to do so, subject to the following conditions:
//
//The above copyright notice and this permission notice shall be included in all
//copies or substantial portions of the Software.
//
//THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//SOFTWARE.

package fijkplayer_max

import (
	"fmt"
	"github.com/go-flutter-desktop/go-flutter"
	"github.com/go-flutter-desktop/go-flutter/plugin"
)

const channelName = "befovy.com/fijkplayer_max"

// FijkplayerMaxPlugin implements flutter.Plugin and handles method.
type FijkplayerMaxPlugin struct {
	sink *plugin.EventSink

	textureRegistry *flutter.TextureRegistry
	messenger       plugin.BinaryMessenger

	eventListening bool

	fijkPlayers map[int32]*FijkPlayer
	playingCnt  int
	playableCnt int
}

var _ flutter.Plugin = &FijkplayerMaxPlugin{} // compile-time type check
var _ flutter.PluginTexture = &FijkplayerMaxPlugin{}

var pluginInstance *FijkplayerMaxPlugin

// InitPlugin initializes the plugin.
func (p *FijkplayerMaxPlugin) InitPlugin(messenger plugin.BinaryMessenger) error {

	pluginInstance = p
	p.messenger = messenger
	p.fijkPlayers = make(map[int32]*FijkPlayer)
	channel := plugin.NewMethodChannel(messenger, channelName, plugin.StandardMethodCodec{})
	channel.HandleFunc("getPlatformVersion", p.handlePlatformVersion)
	channel.HandleFunc("createPlayer", p.handleCreatePlayer)
	channel.HandleFunc("releasePlayer", p.handleReleasePlayer)

	channel.CatchAllHandleFunc(warning)

	eventChannel := plugin.NewEventChannel(messenger, "befovy.com/fijkplayer_max/event", plugin.StandardMethodCodec{})
	eventChannel.Handle(p)

	ijkGlobalInit()
	return nil
}

func warning(methodCall interface{}) (interface{}, error) {
	method := methodCall.(plugin.MethodCall)
	fmt.Println("com.befovy.fijkplayer_max   WARNING   MethodCall to '",
		method.Method, "' isn't supported by the fijkplayer_max")
	return nil, nil
}

// OnListen handles a request to set up an event stream.
func (p *FijkplayerMaxPlugin) OnListen(arguments interface{}, sink *plugin.EventSink) {
	p.sink = sink
}

// OnCancel handles a request to tear down the most recently created event
// stream.
func (p *FijkplayerMaxPlugin) OnCancel(arguments interface{}) {
	p.sink = nil
}

func (p *FijkplayerMaxPlugin) InitPluginTexture(registry *flutter.TextureRegistry) error {
	p.textureRegistry = registry
	return nil
}

func (p *FijkplayerMaxPlugin) onPlayingChange(delta int) {
	p.playingCnt += delta
}

func (p *FijkplayerMaxPlugin) onPlayableChange(delta int) {
	p.playableCnt += delta
}

func (p *FijkplayerMaxPlugin) handlePlatformVersion(arguments interface{}) (reply interface{}, err error) {
	return "go-flutter " + flutter.PlatformVersion, nil
}

func (p *FijkplayerMaxPlugin) handleCreatePlayer(arguments interface{}) (reply interface{}, err error) {
	player := &FijkPlayer{}
	player.initPlayer(p.messenger, p.textureRegistry)
	pid := player.getId()
	p.fijkPlayers[pid] = player
	return pid, nil
}

func (p *FijkplayerMaxPlugin) handleReleasePlayer(arguments interface{}) (reply interface{}, err error) {
	args := arguments.(map[interface{}]interface{})
	if _pid, ok := args["pid"]; ok {
		pid := _pid.(int32)
		if player, exist := p.fijkPlayers[pid]; exist {
			player.release()
		}
		delete(p.fijkPlayers, pid)
	}
	return nil, nil
}

func (p *FijkplayerMaxPlugin) handleLogLevel(arguments interface{}) (reply interface{}, err error) {
	args := arguments.(map[interface{}]interface{})
	level := 500
	if l, ok := args["level"]; ok {
		level = l.(int)
	}
	level = level / 100
	if level < 0 {
		level = 0
	}
	if level > 8 {
		level = 8
	}
	ijkSetLogLevel(level)
	return nil, nil
}
