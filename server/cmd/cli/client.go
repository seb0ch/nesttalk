package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"time"

	"github.com/google/uuid"
	"github.com/seb0ch/nesttalk/server/internal/control"
)

// Client is a one-shot RPC sender against the unix socket.
type Client struct {
	SocketPath string
}

func newClient() *Client {
	return &Client{SocketPath: socketPath}
}

// Call sends a single request and decodes the typed result into out.
func (c *Client) Call(cmd string, args any, out any) error {
	conn, err := net.DialTimeout("unix", c.SocketPath, 5*time.Second)
	if err != nil {
		return fmt.Errorf("dial %s: %w", c.SocketPath, err)
	}
	defer conn.Close()

	argsBytes, err := json.Marshal(args)
	if err != nil {
		return err
	}
	req := control.Request{
		ID:    1,
		CmdID: uuid.NewString(),
		Cmd:   cmd,
		Args:  argsBytes,
	}
	body, err := json.Marshal(req)
	if err != nil {
		return err
	}
	if _, err := conn.Write(append(body, '\n')); err != nil {
		return err
	}
	scanner := bufio.NewScanner(conn)
	scanner.Buffer(make([]byte, 64*1024), 1024*1024)
	if !scanner.Scan() {
		if err := scanner.Err(); err != nil {
			return err
		}
		return errors.New("server closed connection without response")
	}
	var resp control.Response
	if err := json.Unmarshal(scanner.Bytes(), &resp); err != nil {
		return err
	}
	if !resp.OK {
		return errors.New(resp.Error)
	}
	if out != nil {
		return json.Unmarshal(resp.Result, out)
	}
	return nil
}
