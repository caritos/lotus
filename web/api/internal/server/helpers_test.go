package server

import "app/internal/config"

func configDev() config.Config { return config.Config{PublicOrigin: "https://app.example"} }
