library ieee;
use ieee.std_logic_1164.all;

-- MM2S --yuyv--> yuyv2gray --gray32--> unpack --gray8--> sobel3x3 --edge8--> pack --edge32--> S2MM
--
-- Signals between blocks are named after the link (what flows on it), not after one of its
-- ends: each link is the m_axis port of one block and the s_axis port of the next.
--   yuyv   : M_AXIS_MM2S_0_*  (DMA -> yuyv2gray), 32 bit, 2 YUYV pixels per word
--   gray32 : yuyv2gray -> unpack, 32 bit, 4 gray pixels per word
--   gray8  : unpack -> sobel,     8 bit, 1 gray pixel per beat
--   edge8  : sobel -> pack,       8 bit, 1 edge pixel per beat
--   edge32 : S_AXIS_S2MM_0_*  (pack -> DMA), 32 bit, 4 edge pixels per word

entity fpga_top is
end entity fpga_top;

architecture rtl of fpga_top is

  constant C_WIDTH  : positive := 640;
  constant C_HEIGHT : positive := 480;

  signal M_AXIS_MM2S_0_tdata  : std_logic_vector(31 downto 0);
  signal M_AXIS_MM2S_0_tkeep  : std_logic_vector(3 downto 0);
  signal M_AXIS_MM2S_0_tlast  : std_logic;
  signal M_AXIS_MM2S_0_tready : std_logic;
  signal M_AXIS_MM2S_0_tvalid : std_logic;
  signal S_AXIS_S2MM_0_tdata  : std_logic_vector(31 downto 0);
  signal S_AXIS_S2MM_0_tkeep  : std_logic_vector(3 downto 0);
  signal S_AXIS_S2MM_0_tlast  : std_logic;
  signal S_AXIS_S2MM_0_tready : std_logic;
  signal S_AXIS_S2MM_0_tvalid : std_logic;

  signal gray32_tdata  : std_logic_vector(31 downto 0);
  signal gray32_tlast  : std_logic;
  signal gray32_tvalid : std_logic;
  signal gray32_tready : std_logic;

  signal gray8_tdata   : std_logic_vector(7 downto 0);
  signal gray8_tlast   : std_logic;
  signal gray8_tvalid  : std_logic;
  signal gray8_tready  : std_logic;

  signal edge8_tdata   : std_logic_vector(7 downto 0);
  signal edge8_tlast   : std_logic;
  signal edge8_tvalid  : std_logic;
  signal edge8_tready  : std_logic;

  signal clk  : std_logic;
  signal rst  : std_logic;
  signal rstn : std_logic;

begin

  rst <= not rstn;

  -- yuyv -> gray32
  i_yuyv2gray : entity work.yuyv2gray
    port map (
      clk => clk,
      rst => rst,

      m_axis_mm2s_tdata  => M_AXIS_MM2S_0_tdata,
      m_axis_mm2s_tkeep  => M_AXIS_MM2S_0_tkeep,
      m_axis_mm2s_tlast  => M_AXIS_MM2S_0_tlast,
      m_axis_mm2s_tready => M_AXIS_MM2S_0_tready,
      m_axis_mm2s_tvalid => M_AXIS_MM2S_0_tvalid,

      s_axis_s2mm_tdata  => gray32_tdata,
      s_axis_s2mm_tkeep  => open,               -- always "1111"
      s_axis_s2mm_tlast  => gray32_tlast,
      s_axis_s2mm_tready => gray32_tready,
      s_axis_s2mm_tvalid => gray32_tvalid
    );

  -- gray32 -> gray8
  i_unpack : entity work.axis_unpack32to8
    port map (
      clk => clk,
      rst => rst,

      s_axis_tdata  => gray32_tdata,
      s_axis_tvalid => gray32_tvalid,
      s_axis_tready => gray32_tready,
      s_axis_tlast  => gray32_tlast,

      m_axis_tdata  => gray8_tdata,
      m_axis_tvalid => gray8_tvalid,
      m_axis_tready => gray8_tready,
      m_axis_tlast  => gray8_tlast
    );

  -- gray8 -> edge8
  i_sobel : entity work.sobel3x3
    generic map (
      G_WIDTH  => C_WIDTH,
      G_HEIGHT => C_HEIGHT
    )
    port map (
      clk => clk,
      rst => rst,

      s_axis_tdata  => gray8_tdata,
      s_axis_tvalid => gray8_tvalid,
      s_axis_tready => gray8_tready,
      s_axis_tlast  => gray8_tlast,

      m_axis_tdata  => edge8_tdata,
      m_axis_tvalid => edge8_tvalid,
      m_axis_tready => edge8_tready,
      m_axis_tlast  => edge8_tlast
    );

  -- edge8 -> edge32
  i_pack : entity work.axis_pack8to32
    port map (
      clk => clk,
      rst => rst,

      s_axis_tdata  => edge8_tdata,
      s_axis_tvalid => edge8_tvalid,
      s_axis_tready => edge8_tready,
      s_axis_tlast  => edge8_tlast,

      m_axis_tdata  => S_AXIS_S2MM_0_tdata,
      m_axis_tvalid => S_AXIS_S2MM_0_tvalid,
      m_axis_tready => S_AXIS_S2MM_0_tready,
      m_axis_tlast  => S_AXIS_S2MM_0_tlast,
      m_axis_tkeep  => open                     -- not driven inside pack, see below
    );

  S_AXIS_S2MM_0_tkeep <= "1111";               -- every output word is full

  kria_system : entity work.design_1_wrapper
    port map (
      pl_clk0_0               => clk,
      peripheral_aresetn_0(0) => rstn,

      M_AXIS_MM2S_0_tdata  => M_AXIS_MM2S_0_tdata,
      M_AXIS_MM2S_0_tkeep  => M_AXIS_MM2S_0_tkeep,
      M_AXIS_MM2S_0_tlast  => M_AXIS_MM2S_0_tlast,
      M_AXIS_MM2S_0_tready => M_AXIS_MM2S_0_tready,
      M_AXIS_MM2S_0_tvalid => M_AXIS_MM2S_0_tvalid,
      S_AXIS_S2MM_0_tdata  => S_AXIS_S2MM_0_tdata,
      S_AXIS_S2MM_0_tkeep  => S_AXIS_S2MM_0_tkeep,
      S_AXIS_S2MM_0_tlast  => S_AXIS_S2MM_0_tlast,
      S_AXIS_S2MM_0_tready => S_AXIS_S2MM_0_tready,
      S_AXIS_S2MM_0_tvalid => S_AXIS_S2MM_0_tvalid
    );

end architecture;
