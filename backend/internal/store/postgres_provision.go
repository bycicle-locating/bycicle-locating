package store

import "context"

func (p *Postgres) CreateDevice(ctx context.Context, d Device, claimCodeHash string) error {
	created, err := p.insertDevice(ctx, d, claimCodeHash)
	if err != nil {
		return err
	}
	if !created {
		return ErrDeviceExists
	}
	return nil
}
